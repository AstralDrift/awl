//! Minimal HTTP/1.1 client over a raw IPv4 socket. Plain HTTP only (localhost).
//! Body is written from caller-owned segments (no request buffer); the
//! response is read through a fixed 16 KB buffer and de-chunked line by line.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;

pub const Url = struct {
    ip: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 80,
    host: []const u8 = "127.0.0.1",
    prefix: []const u8 = "", // path before /v1, e.g. "/run/7" behind a proxy
};

pub const Error = error{ BadUrl, Connect, Http, Closed, Cancel } || sys.Error;

pub fn parseUrl(s0: []const u8) Error!Url {
    var s = s0;
    if (std.mem.startsWith(u8, s, "http://")) s = s[7..] else if (std.mem.indexOf(u8, s, "://") != null) return error.BadUrl;
    var prefix: []const u8 = "";
    if (std.mem.indexOfScalar(u8, s, '/')) |i| {
        prefix = std.mem.trimEnd(u8, s[i..], "/");
        if (std.mem.endsWith(u8, prefix, "/v1")) prefix = prefix[0 .. prefix.len - 3];
        s = s[0..i];
    }
    var u = Url{ .host = s, .prefix = prefix };
    var host = s;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |i| {
        u.port = std.fmt.parseInt(u16, s[i + 1 ..], 10) catch return error.BadUrl;
        host = s[0..i];
    }
    if (std.mem.eql(u8, host, "localhost")) return u;
    var it = std.mem.splitScalar(u8, host, '.');
    for (&u.ip) |*b| b.* = std.fmt.parseInt(u8, it.next() orelse return error.BadUrl, 10) catch return error.BadUrl;
    if (it.next() != null) return error.BadUrl;
    return u;
}

/// Block until `fd` is readable. SIGINT (via sys.sigfd) turns into error.Cancel.
/// timeout_ms < 0 waits forever; returns false on timeout.
pub fn wait(fd: sys.fd_t, timeout_ms: i32) Error!bool {
    var p = [2]linux.pollfd{
        .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = sys.sigfd, .events = linux.POLL.IN, .revents = 0 },
    };
    var left = timeout_ms;
    while (true) {
        // With a tick hook, wake in slices to let the UI redraw and read keys.
        const slice: i32 = if (sys.tick != null and (left < 0 or left > sys.tick_ms)) sys.tick_ms else left;
        const n = sys.check(linux.poll(&p, if (sys.sigfd >= 0) 2 else 1, slice)) catch |e| {
            if (e == error.Interrupted) continue;
            return e;
        };
        if (n == 0) {
            if (slice == left) return false;
            if (left > 0) left -= slice;
            sys.maybeTick();
            continue;
        }
        sys.maybeTick();
        if (p[1].revents != 0) {
            sys.drainSignals();
            return error.Cancel;
        }
        return true;
    }
}

pub fn connect(u: Url) Error!sys.fd_t {
    const fd: sys.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, u.port), .addr = @bitCast(u.ip) };
    _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) catch return error.Connect;
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
    return fd;
}

/// Send a request. `body` segments are written back to back after the header.
pub fn send(fd: sys.fd_t, u: Url, method: []const u8, path: []const u8, key: ?[]const u8, body: []const []const u8) Error!void {
    var total: usize = 0;
    for (body) |b| total += b.len;
    var hb: [1024]u8 = undefined;
    var auth_b: [600]u8 = undefined;
    const auth = if (key) |k| std.fmt.bufPrint(&auth_b, "Authorization: Bearer {s}\r\n", .{k}) catch "" else "";
    const head = std.fmt.bufPrint(&hb, "{s} {s}{s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: awl\r\nAccept: text/event-stream\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n", .{ method, u.prefix, path, u.host, total, auth }) catch return error.Http;
    try sys.writeAll(fd, head);
    for (body) |b| try sys.writeAll(fd, b);
}

pub const Response = struct {
    fd: sys.fd_t,
    buf: [16 * 1024]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,
    status: u16 = 0,
    chunked: bool = false,
    left: ?usize = null, // Content-Length remaining, or bytes left in current chunk
    done: bool = false,
    crlf: bool = false, // a chunk's trailing CRLF is still unread
    line: Buf = Buf.init(64 << 20),
    carry: usize = 0,

    fn fill(self: *Response) Error!bool {
        if (self.pos == self.end) {
            self.pos = 0;
            self.end = 0;
        } else if (self.end == self.buf.len) {
            std.mem.copyForwards(u8, &self.buf, self.buf[self.pos..self.end]);
            self.end -= self.pos;
            self.pos = 0;
        }
        _ = try wait(self.fd, -1);
        const n = try sys.read(self.fd, self.buf[self.end..]);
        self.end += n;
        return n > 0;
    }

    /// A raw CRLF line from the wire (headers, chunk sizes). Short lines only.
    fn rawLine(self: *Response) Error![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.buf[self.pos..self.end], '\n')) |i| {
                const l = self.buf[self.pos .. self.pos + i];
                self.pos += i + 1;
                return std.mem.trimEnd(u8, l, "\r");
            }
            if (self.end - self.pos == self.buf.len) return error.Http;
            if (!try self.fill()) return error.Closed;
        }
    }

    pub fn readHead(self: *Response) Error!void {
        const st = try self.rawLine();
        if (st.len < 12 or !std.mem.startsWith(u8, st, "HTTP/1.")) return error.Http;
        self.status = std.fmt.parseInt(u16, st[9..12], 10) catch return error.Http;
        while (true) {
            const h = try self.rawLine();
            if (h.len == 0) break;
            const c = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            const name = h[0..c];
            const val = std.mem.trim(u8, h[c + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.indexOfIgnoreCase(val, "chunked") != null) self.chunked = true;
            if (std.ascii.eqlIgnoreCase(name, "content-length")) self.left = std.fmt.parseInt(usize, val, 10) catch null;
        }
        if (self.chunked) self.left = 0;
    }

    /// Next run of decoded body bytes, or null at end of body.
    pub fn body(self: *Response) Error!?[]const u8 {
        if (self.done) return null;
        if (self.chunked and self.left.? == 0) {
            if (self.crlf) _ = try self.rawLine(); // end of the previous chunk
            self.crlf = true;
            const sz = try self.rawLine();
            const hex = sz[0 .. std.mem.indexOfScalar(u8, sz, ';') orelse sz.len];
            const n = std.fmt.parseInt(usize, std.mem.trim(u8, hex, " "), 16) catch return error.Http;
            if (n == 0) {
                self.done = true;
                return null;
            }
            self.left = n;
        }
        if (self.pos == self.end and !try self.fill()) {
            self.done = true;
            if (self.chunked or (self.left != null and self.left.? > 0)) return error.Closed;
            return null;
        }
        var n = self.end - self.pos;
        if (self.left) |l| n = @min(n, l);
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        if (self.left) |*l| {
            l.* -= n;
            if (!self.chunked and l.* == 0) self.done = true;
        }
        return out;
    }

    /// Next body line without the trailing newline, or null at end.
    /// The returned slice is valid until the next call.
    pub fn nextLine(self: *Response) Error!?[]const u8 {
        self.consume();
        while (true) {
            const have = self.line.items();
            if (std.mem.indexOfScalar(u8, have, '\n')) |i| {
                const l = std.mem.trimEnd(u8, have[0..i], "\r");
                self.carry = i + 1;
                return l;
            }
            const b = try self.body() orelse {
                if (have.len == 0) return null;
                self.carry = have.len;
                return have;
            };
            self.line.add(b);
        }
    }
    fn consume(self: *Response) void {
        if (self.carry == 0) return;
        const rest = self.line.items()[self.carry..];
        std.mem.copyForwards(u8, self.line.items()[0..rest.len], rest);
        self.line.truncate(rest.len);
        self.carry = 0;
    }

    pub fn deinit(self: *Response) void {
        sys.close(self.fd);
        self.line.free();
    }
};

test "parseUrl" {
    const u = try parseUrl("http://127.0.0.1:12434/v1");
    try std.testing.expectEqual(@as(u16, 12434), u.port);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &u.ip);
    try std.testing.expectEqualStrings("127.0.0.1:12434", u.host);
    try std.testing.expectEqualStrings("", u.prefix);
    try std.testing.expectEqualStrings("/run/7", (try parseUrl("http://localhost:9/run/7/v1/")).prefix);
    try std.testing.expectError(error.BadUrl, parseUrl("https://x"));
}
