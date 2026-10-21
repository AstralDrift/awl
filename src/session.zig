//! Sessions: one JSON message per line in ~/.local/state/awl/sessions/<utc>.jsonl.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;

pub var fd: sys.fd_t = -1;
pub var path_b: [512]u8 = undefined;
pub var path: []const u8 = "";

fn dir(buf: []u8) ?[]const u8 {
    if (sys.getenv("XDG_STATE_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/awl/sessions", .{x}) catch null;
    const home = sys.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/awl/sessions", .{home}) catch null;
}

fn mkdirs(p: []const u8) void {
    var zb: [512]u8 = undefined;
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (i < p.len and p[i] != '/') continue;
        _ = linux.mkdirat(linux.AT.FDCWD, sys.z(&zb, p[0..i]), 0o700);
    }
}

/// Start a new session file. Failure leaves sessions off (fd = -1).
pub fn create(meta: []const u8) void {
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return;
    mkdirs(d);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(sys.wallSec()) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    path = std.fmt.bufPrint(&path_b, "{s}/{d}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}.jsonl", .{ d, day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), linux.getpid() }) catch return;
    fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch return;
    append(meta);
}

pub fn append(json: []const u8) void {
    if (fd < 0) return;
    sys.writeAll(fd, json) catch {};
    sys.writeAll(fd, "\n") catch {};
}

/// Load messages from `p` into `msgs` (each prefixed with a comma). Reopens it for append.
pub fn load(p: []const u8, msgs: *Buf) !usize {
    var mb = Buf.init(1 << 30);
    defer mb.free();
    const f = try sys.open(p, .{ .CLOEXEC = true }, 0);
    while (true) {
        const dst = mb.extend(1 << 16);
        const n = try sys.read(f, dst);
        mb.truncate(mb.len - (dst.len - n));
        if (n == 0) break;
    }
    sys.close(f);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, mb.items(), '\n');
    while (it.next()) |line| {
        if (line.len < 2 or std.mem.startsWith(u8, line, "{\"awl\"")) continue;
        msgs.byte(',');
        msgs.add(line);
        count += 1;
    }
    path = path_b[0..@min(p.len, path_b.len)];
    @memcpy(@constCast(path), p[0..path.len]);
    fd = sys.open(p, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0) catch -1;
    return count;
}

/// Newest session file path (names sort by time).
pub fn latest(out: []u8) ?[]const u8 {
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return null;
    const dfd = sys.open(d, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return null;
    defer sys.close(dfd);
    var best: [128]u8 = undefined;
    var best_n: usize = 0;
    var b: [8192]u8 align(8) = undefined;
    while (true) {
        const n = sys.check(linux.getdents64(dfd, &b, b.len)) catch return null;
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off + @offsetOf(linux.dirent64, "name")])), 0);
            if (std.mem.endsWith(u8, name, ".jsonl") and name.len <= best.len and std.mem.order(u8, name, best[0..best_n]) == .gt) {
                @memcpy(best[0..name.len], name);
                best_n = name.len;
            }
            off += e.reclen;
        }
    }
    if (best_n == 0) return null;
    return std.fmt.bufPrint(out, "{s}/{s}", .{ d, best[0..best_n] }) catch null;
}
