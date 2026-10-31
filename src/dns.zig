//! Host names for AWL_URL without libc: /etc/hosts first, then one A query over UDP to each
//! nameserver in /etc/resolv.conf (2 s each). IPv4 only, like the rest of http.zig.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// The IPv4 address of `name`, or null when nothing answers.
pub fn resolve(name: []const u8) ?[4]u8 {
    if (name.len == 0 or name.len > 253) return null;
    var fb: [64 * 1024]u8 = undefined;
    if (sys.readFile("/etc/hosts", &fb)) |hosts| {
        if (fromHosts(hosts, name)) |ip| return ip;
    } else |_| {}
    const conf = sys.readFile("/etc/resolv.conf", &fb) catch return null;
    var it = std.mem.splitScalar(u8, conf, '\n');
    var tried: usize = 0;
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "nameserver")) continue;
        const ns = parseIp(std.mem.trim(u8, line["nameserver".len..], " \t\r")) orelse continue;
        tried += 1;
        if (query(ns, name)) |ip| return ip;
        if (tried == 3) break;
    }
    return null;
}

/// "a.b.c.d" as bytes, else null.
pub fn parseIp(s: []const u8) ?[4]u8 {
    var ip: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&ip) |*b| b.* = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return ip;
}

fn fromHosts(text: []const u8, name: []const u8) ?[4]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l0| {
        const l = l0[0 .. std.mem.indexOfScalar(u8, l0, '#') orelse l0.len];
        var w = std.mem.tokenizeAny(u8, l, " \t\r");
        const ip = parseIp(w.next() orelse continue) orelse continue;
        while (w.next()) |h| if (std.ascii.eqlIgnoreCase(h, name)) return ip;
    }
    return null;
}

fn query(ns: [4]u8, name: []const u8) ?[4]u8 {
    var pkt: [512]u8 = undefined;
    var id: [2]u8 = undefined;
    _ = linux.getrandom(&id, 2, 0);
    const n = buildQuery(&pkt, id, name) orelse return null;
    const fd: i32 = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0)) catch return null);
    defer sys.close(fd);
    var addr = linux.sockaddr.in{ .port = std.mem.nativeToBig(u16, 53), .addr = @bitCast(ns) };
    _ = sys.check(linux.sendto(fd, &pkt, n, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) catch return null;
    var p = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const ready = sys.check(linux.poll(&p, 1, 2000)) catch return null;
    if (ready == 0) return null;
    var rb: [1024]u8 = undefined;
    const got = sys.check(linux.recvfrom(fd, &rb, rb.len, 0, null, null)) catch return null;
    return parseAnswer(rb[0..got], id);
}

/// A standard recursive A query for `name`; its length in `pkt`, or null for a bad name.
pub fn buildQuery(pkt: *[512]u8, id: [2]u8, name: []const u8) ?usize {
    pkt[0..12].* = .{ id[0], id[1], 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0 };
    var n: usize = 12;
    var labels = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "."), '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63 or n + 1 + l.len + 5 > pkt.len) return null;
        pkt[n] = @intCast(l.len);
        @memcpy(pkt[n + 1 .. n + 1 + l.len], l);
        n += 1 + l.len;
    }
    pkt[n..][0..5].* = .{ 0, 0, 1, 0, 1 }; // root label, type A, class IN
    return n + 5;
}

/// The first A record in a reply to the query `id`, or null (wrong id, error code, no A record).
pub fn parseAnswer(r: []const u8, id: [2]u8) ?[4]u8 {
    if (r.len < 12 or r[0] != id[0] or r[1] != id[1] or (r[3] & 0x0f) != 0) return null;
    const qd = std.mem.readInt(u16, r[4..6], .big);
    const an = std.mem.readInt(u16, r[6..8], .big);
    var i: usize = 12;
    for (0..qd) |_| i = (skipName(r, i) orelse return null) + 4;
    for (0..an) |_| {
        i = skipName(r, i) orelse return null;
        if (i + 10 > r.len) return null;
        const typ = std.mem.readInt(u16, r[i..][0..2], .big);
        const len = std.mem.readInt(u16, r[i + 8 ..][0..2], .big);
        i += 10;
        if (i + len > r.len) return null;
        if (typ == 1 and len == 4) return r[i..][0..4].*;
        i += len;
    }
    return null;
}

/// Past a (possibly compressed) name starting at `i`.
fn skipName(r: []const u8, start: usize) ?usize {
    var i = start;
    while (i < r.len) {
        const c = r[i];
        if (c == 0) return i + 1;
        if (c & 0xc0 == 0xc0) return if (i + 2 <= r.len) i + 2 else null;
        i += 1 + c;
    }
    return null;
}

test "dns: query layout and answer parsing with a compressed name and a CNAME first" {
    var pkt: [512]u8 = undefined;
    const n = buildQuery(&pkt, .{ 0xab, 0xcd }, "api.example.com").?;
    try std.testing.expectEqual(@as(usize, 12 + 1 + 3 + 1 + 7 + 1 + 3 + 1 + 4), n);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, 'a', 'p', 'i' }, pkt[0..16]);
    // reply: same question, then CNAME (compressed name, 5-byte rdata) and an A record
    var r: [128]u8 = undefined;
    @memcpy(r[0..n], pkt[0..n]);
    r[2] = 0x81;
    r[3] = 0x80;
    r[7] = 2;
    var i = n;
    r[i..][0..12].* = .{ 0xc0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, 5 }; // CNAME: name ptr, type 5, class, ttl, rdlen 5
    i += 12;
    r[i..][0..5].* = .{ 1, 'x', 0xc0, 16, 0 };
    i += 5;
    r[i..][0..14].* = .{ 0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 1 };
    i += 14;
    r[i..][0..2].* = .{ 2, 3 };
    i += 2;
    try std.testing.expectEqualSlices(u8, &.{ 10, 1, 2, 3 }, &parseAnswer(r[0..i], .{ 0xab, 0xcd }).?);
    try std.testing.expect(parseAnswer(r[0..i], .{ 0xab, 0xce }) == null); // wrong id
    r[3] = 0x83; // NXDOMAIN
    try std.testing.expect(parseAnswer(r[0..i], .{ 0xab, 0xcd }) == null);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &fromHosts("# c\n127.0.0.1 localhost Awl-Host # x\n::1 ip6\n", "awl-host").?);
    try std.testing.expect(fromHosts("127.0.0.1 localhost\n", "other") == null);
    try std.testing.expect(parseIp("1.2.3") == null and parseIp("1.2.3.4").?[3] == 4);
}
