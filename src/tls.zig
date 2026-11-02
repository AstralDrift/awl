//! HTTPS for AWL_URL: std.crypto.tls over awl's raw socket, no libc. One connection at a time
//! (awl never has two model requests in flight), so the client and its buffers are globals.
//! Server certificates are checked against the system CA bundle (or AWL_CA_FILE).
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const http = @import("http.zig");
const Buf = @import("buf.zig").Buf;

const Client = std.crypto.tls.Client;
const Bundle = std.crypto.Certificate.Bundle;

pub const Error = error{ Tls, Closed, Cancel };

var fd: i32 = -1;
var cancelled = false;
var sock_in: std.Io.Reader = undefined;
var sock_out: std.Io.Writer = undefined;
var in_buf: [Client.min_buffer_len]u8 = undefined;
var out_buf: [Client.min_buffer_len]u8 = undefined;
var tls_in: [Client.min_buffer_len]u8 = undefined;
var tls_out: [Client.min_buffer_len]u8 = undefined;
var client: Client = undefined;
var bundle: Bundle = .empty;
var bundle_loaded = false;
var bundle_lock: std.Io.RwLock = .init;
/// The last failure, for the error message.
pub var detail: []const u8 = "";

// The TLS client takes an Io only for its RwLock and for re-reading the OS trust store on Windows; on Linux
// the uncontended lock never calls into it and the rescan path is compiled out (Certificate.Chain is void).
const no_io: std.Io = .{ .userdata = null, .vtable = undefined };

const sock_in_vt: std.Io.Reader.VTable = .{ .stream = streamIn };
const sock_out_vt: std.Io.Writer.VTable = .{ .drain = drainOut };

fn streamIn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    _ = r;
    const dest = limit.slice(try w.writableSliceGreedy(1));
    _ = http.wait(fd, -1) catch |e| {
        if (e == error.Cancel) cancelled = true;
        return error.ReadFailed;
    };
    const n = sys.read(fd, dest) catch return error.ReadFailed;
    if (n == 0) return error.EndOfStream;
    w.advance(n);
    return n;
}

fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    sys.writeAll(fd, w.buffered()) catch return error.WriteFailed;
    var n: usize = w.end;
    for (data[0 .. data.len - 1]) |d| {
        sys.writeAll(fd, d) catch return error.WriteFailed;
        n += d.len;
    }
    for (0..splat) |_| {
        sys.writeAll(fd, data[data.len - 1]) catch return error.WriteFailed;
        n += data[data.len - 1].len;
    }
    return w.consume(n);
}

/// Handshake on the connected socket `s` as a client for `host`. `detail` says why on failure.
pub fn connect(s: i32, host: []const u8) Error!void {
    fd = s;
    cancelled = false;
    loadBundle() catch |e| {
        detail = switch (e) {
            error.NoBundle => "no CA bundle found (set AWL_CA_FILE)",
            else => "the CA bundle could not be read",
        };
        return error.Tls;
    };
    sock_in = .{ .vtable = &sock_in_vt, .buffer = &in_buf, .seek = 0, .end = 0 };
    sock_out = .{ .vtable = &sock_out_vt, .buffer = &out_buf, .end = 0 };
    var entropy: [Client.Options.entropy_len]u8 = undefined;
    _ = linux.getrandom(&entropy, entropy.len, 0);
    client = Client.init(&sock_in, &sock_out, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = .{ .gpa = std.heap.page_allocator, .io = no_io, .lock = &bundle_lock, .bundle = &bundle } },
        .write_buffer = &tls_out,
        .read_buffer = &tls_in,
        .entropy = &entropy,
        .realtime_now = .{ .nanoseconds = @as(i96, sys.wallSec()) * std.time.ns_per_s },
        .allow_truncation_attacks = true, // HTTP frames the body itself (Content-Length / chunked)
    }) catch |e| {
        if (cancelled) return error.Cancel;
        detail = @errorName(e);
        return error.Tls;
    };
}

pub fn writeAll(data: []const u8) Error!void {
    client.writer.writeAll(data) catch return error.Closed;
}

/// Encrypt what is buffered and send it: the TLS writer drains into the socket writer's buffer, so both flush.
pub fn flush() Error!void {
    client.writer.flush() catch return error.Closed;
    sock_out.flush() catch return error.Closed;
}

/// Some decrypted bytes into `dest` (at least one, blocking for the next record); 0 at the end of the stream.
pub fn read(dest: []u8) Error!usize {
    const r = &client.reader;
    if (r.buffered().len == 0) r.fill(1) catch |e| switch (e) {
        error.EndOfStream => return 0,
        error.ReadFailed => return if (cancelled) error.Cancel else error.Closed,
    };
    const have = r.buffered();
    const n = @min(have.len, dest.len);
    @memcpy(dest[0..n], have[0..n]);
    r.toss(n);
    return n;
}

const bundle_paths = [_][]const u8{
    "/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Arch, Alpine
    "/etc/pki/tls/certs/ca-bundle.crt", // Fedora, RHEL
    "/etc/ssl/ca-bundle.pem", // openSUSE
    "/etc/ssl/cert.pem", // macOS-style layouts, some containers
};

/// The CA bundle, once per process: AWL_CA_FILE, else the first well-known path. PEM blocks are decoded
/// into the bundle's byte store and indexed by subject with std's own parser; expired ones are dropped.
fn loadBundle() error{ NoBundle, Decode, OutOfMemory }!void {
    if (bundle_loaded) return;
    const path = sys.getenv("AWL_CA_FILE") orelse for (bundle_paths) |p| {
        if (sys.exists(p)) break p;
    } else return error.NoBundle;
    var pem = Buf.init(8 << 20);
    defer pem.free();
    const f = sys.open(path, .{ .CLOEXEC = true }, 0) catch return error.NoBundle;
    defer sys.close(f);
    while (true) {
        const dst = pem.extend(1 << 16);
        const got = sys.read(f, dst) catch return error.NoBundle;
        pem.truncate(pem.len - (dst.len - got));
        if (got == 0) break;
    }
    const gpa = std.heap.page_allocator;
    const now = sys.wallSec();
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var text = pem.items();
    var count: usize = 0;
    while (std.mem.indexOf(u8, text, "-----BEGIN CERTIFICATE-----")) |b| {
        const body_start = b + "-----BEGIN CERTIFICATE-----".len;
        const e = std.mem.indexOfPos(u8, text, body_start, "-----END CERTIFICATE-----") orelse break;
        const b64 = text[body_start..e];
        text = text[e + "-----END CERTIFICATE-----".len ..];
        const start = bundle.bytes.items.len;
        try bundle.bytes.ensureUnusedCapacity(gpa, decoder.calcSizeUpperBound(b64.len));
        const n = decoder.decode(bundle.bytes.unusedCapacitySlice(), b64) catch return error.Decode;
        bundle.bytes.items.len += n;
        bundle.parseCert(gpa, @intCast(start), now) catch {
            bundle.bytes.items.len = start; // one unparsable certificate does not spoil the bundle
            continue;
        };
        count += 1;
    }
    if (count == 0) return error.NoBundle;
    bundle_loaded = true;
}

test "tls: the system bundle loads when present" {
    if (!sys.exists(bundle_paths[0]) and sys.getenv("AWL_CA_FILE") == null) return;
    try loadBundle();
    try std.testing.expect(bundle.map.count() > 0);
}
