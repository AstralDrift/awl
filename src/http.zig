//! Minimal HTTP/1.1 client over a raw IPv4 socket: plain HTTP, or HTTPS through tls.zig
//! (std.crypto.tls) with host names resolved by dns.zig. Body is written from caller-owned
//! segments (no request buffer); the response is read through a fixed 16 KB buffer and
//! de-chunked line by line.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const dns = @import("dns.zig");
const tls = @import("tls.zig");
const Buf = @import("buf.zig").Buf;

pub const Url = struct {
    ip: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16 = 80,
    host: []const u8 = "127.0.0.1", // as typed: name or address, with its port if any
    name: []const u8 = "127.0.0.1", // host without the port (Host header, TLS server name)
    prefix: []const u8 = "", // path before /v1, e.g. "/run/7" behind a proxy
    tls: bool = false,
    named: bool = false, // ip comes from resolve(), not the URL
};

pub const Error = error{ BadUrl, Connect, Http, Closed, Cancel, Resolve, Tls } || sys.Error;

/// http://host[:port][/prefix] or https://…; a host name needs resolve() before connect().
pub fn parseUrl(s0: []const u8) Error!Url {
    var s = s0;
    var u = Url{};
    if (std.mem.startsWith(u8, s, "http://")) s = s[7..] else if (std.mem.startsWith(u8, s, "https://")) {
        s = s[8..];
        u.tls = true;
        u.port = 443;
    } else if (std.mem.indexOf(u8, s, "://") != null) return error.BadUrl;
    if (std.mem.indexOfScalar(u8, s, '/')) |i| {
        u.prefix = std.mem.trimEnd(u8, s[i..], "/");
        if (std.mem.endsWith(u8, u.prefix, "/v1")) u.prefix = u.prefix[0 .. u.prefix.len - 3];
        s = s[0..i];
    }
    u.host = s;
    u.name = s;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |i| {
        u.port = std.fmt.parseInt(u16, s[i + 1 ..], 10) catch return error.BadUrl;
        u.name = s[0..i];
    }
    if (u.name.len == 0) return error.BadUrl;
    if (std.mem.eql(u8, u.name, "localhost")) return u;
    if (dns.parseIp(u.name)) |ip| {
        u.ip = ip;
        return u;
    }
    for (u.name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.')) return error.BadUrl;
    u.named = true;
    return u;
}

/// Look up a host name once (/etc/hosts, then the resolv.conf nameservers). Addresses pass through.
pub fn resolve(u: *Url) Error!void {
    if (!u.named) return;
    u.ip = dns.resolve(u.name) orelse return error.Resolve;
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

/// A connected socket; for https the TLS handshake is done (tls.detail says why when it fails).
pub fn connect(u: Url) Error!sys.fd_t {
    const fd: sys.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer sys.close(fd);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, u.port), .addr = @bitCast(u.ip) };
    _ = sys.check(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) catch return error.Connect;
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
    if (u.tls) tls.connect(fd, u.name) catch |e| return switch (e) {
        error.Cancel => error.Cancel,
        error.Closed => error.Closed,
        error.Tls => error.Tls,
    };
    return fd;
}

fn writeOut(fd: sys.fd_t, u: Url, data: []const u8) Error!void {
    if (u.tls) tls.writeAll(data) catch return error.Closed else try sys.writeAll(fd, data);
}

/// Send a request. `body` segments are written back to back after the header.
pub fn send(fd: sys.fd_t, u: Url, method: []const u8, path: []const u8, key: ?[]const u8, body: []const []const u8) Error!void {
    var total: usize = 0;
    for (body) |b| total += b.len;
    var hb: [1024]u8 = undefined;
    var auth_b: [600]u8 = undefined;
    const auth = if (key) |k| std.fmt.bufPrint(&auth_b, "Authorization: Bearer {s}\r\n", .{k}) catch "" else "";
    var host_b: [300]u8 = undefined;
    const default_port = u.port == (if (u.tls) @as(u16, 443) else 80);
    const host = if (default_port) u.name else std.fmt.bufPrint(&host_b, "{s}:{d}", .{ u.name, u.port }) catch u.host;
    const head = std.fmt.bufPrint(&hb, "{s} {s}{s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: awl\r\nAccept: text/event-stream\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n", .{ method, u.prefix, path, host, total, auth }) catch return error.Http;
    try writeOut(fd, u, head);
    for (body) |b| try writeOut(fd, u, b);
    if (u.tls) tls.flush() catch return error.Closed;
}

pub const Response = struct {
    fd: sys.fd_t,
    tls: bool = false,
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
        const n = if (self.tls) tls.read(self.buf[self.end..]) catch |e| return switch (e) {
            error.Cancel => error.Cancel,
            else => error.Closed,
        } else blk: {
            _ = try wait(self.fd, -1);
            break :blk try sys.read(self.fd, self.buf[self.end..]);
        };
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
    const h = try parseUrl("https://openrouter.ai/api/v1");
    try std.testing.expect(h.tls and h.named and h.port == 443);
    try std.testing.expectEqualStrings("openrouter.ai", h.name);
    try std.testing.expectEqualStrings("/api", h.prefix);
    const hp = try parseUrl("https://localhost:8443");
    try std.testing.expect(hp.tls and !hp.named and hp.port == 8443 and hp.ip[0] == 127);
    try std.testing.expectError(error.BadUrl, parseUrl("ftp://x"));
    try std.testing.expectError(error.BadUrl, parseUrl("http://bad_host"));
    try std.testing.expectError(error.BadUrl, parseUrl("http://:80"));
}
