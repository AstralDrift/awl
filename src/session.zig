//! Sessions: one JSON message per line in ~/.local/state/awl/sessions/<utc>.jsonl.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;

pub var fd: sys.fd_t = -1;
pub var path_b: [512]u8 = undefined;
pub var path: []const u8 = "";

pub fn dirPath(buf: []u8) ?[]const u8 {
    return dir(buf);
}

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

pub var cwd_b: [4096]u8 = undefined;
pub var start_cwd: []const u8 = ".";
pub var meta_b: [8192]u8 = undefined;
pub var start_meta: []const u8 = "";

/// Start a new session file with the saved meta line (see main).
pub fn restart() void {
    close();
    create(start_meta);
}

/// Start a new session file. Failure leaves sessions off (fd = -1).
pub fn create(meta: []const u8) void {
    fd = newFile(&path_b, &path) orelse return;
    append(meta);
    @import("agents.zig").begin();
}

/// A new, empty session file named for the current UTC time (`out` gets its path).
pub fn newFile(buf: []u8, out: *[]const u8) ?sys.fd_t {
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return null;
    mkdirs(d);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(sys.wallSec()) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    var seq: usize = 0;
    while (seq < 100) : (seq += 1) { // another session in the same second: _1, _2 (sorts after the first)
        var sb: [8]u8 = undefined;
        const suffix = if (seq == 0) "" else std.fmt.bufPrint(&sb, "_{d}", .{seq}) catch "";
        out.* = std.fmt.bufPrint(buf, "{s}/{d}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}{s}.jsonl", .{ d, day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), linux.getpid(), suffix }) catch return null;
        return sys.open(out.*, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch |e| {
            if (e == error.Exists) continue;
            return null;
        };
    }
    return null;
}

pub fn append(json: []const u8) void {
    if (fd < 0) return;
    sys.writeAll(fd, json) catch {};
    sys.writeAll(fd, "\n") catch {};
}

/// Feed each message line of `p` to `onMsg`. Reopens the file for append.
pub fn load(p: []const u8, comptime onMsg: fn ([]const u8) void) !usize {
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
        onMsg(line);
        count += 1;
    }
    path = path_b[0..@min(p.len, path_b.len)];
    @memcpy(@constCast(path), p[0..path.len]);
    fd = sys.open(p, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0) catch -1;
    @import("agents.zig").begin();
    return count;
}

pub const Entry = struct {
    name: [64]u8 = undefined,
    name_n: usize = 0,
    first: [96]u8 = undefined, // first user prompt, one line
    first_n: usize = 0,
    pub fn file(e: *const Entry) []const u8 {
        return e.name[0..e.name_n];
    }
    pub fn prompt(e: *const Entry) []const u8 {
        return e.first[0..e.first_n];
    }
    /// How long ago it started ("just now", "5 min ago", "3 h ago", "2 d ago"). File
    /// names carry UTC, so this needs no time zone.
    pub fn age(e: *const Entry, out: []u8) []const u8 {
        return ago(e.file(), sys.wallSec(), out);
    }
};

/// "20261022-152614-..." (UTC) as an age relative to `now` (Unix seconds).
fn ago(f: []const u8, now: i64, out: []u8) []const u8 {
    if (f.len < 15) return "";
    const n = struct {
        fn n(s: []const u8) i64 {
            return std.fmt.parseInt(i64, s, 10) catch 0;
        }
    }.n;
    // days from 1970-01-01 to y-m-d (Howard Hinnant's days_from_civil)
    var y = n(f[0..4]);
    const m = n(f[4..6]);
    const d = n(f[6..8]);
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const t = days * 86400 + n(f[9..11]) * 3600 + n(f[11..13]) * 60 + n(f[13..15]);
    const s = @max(now - t, 0);
    if (s < 60) return "just now";
    if (s < 3600) return std.fmt.bufPrint(out, "{d} min ago", .{@divFloor(s, 60)}) catch "";
    if (s < 86400) return std.fmt.bufPrint(out, "{d} h ago", .{@divFloor(s, 3600)}) catch "";
    return std.fmt.bufPrint(out, "{d} d ago", .{@divFloor(s, 86400)}) catch "";
}

test "session age from a UTC file name" {
    var b: [32]u8 = undefined;
    // 2026-10-22 15:26:14 UTC = 1792682774
    try std.testing.expectEqualStrings("just now", ago("20261022-152614-9.jsonl", 1792682774 + 30, &b));
    try std.testing.expectEqualStrings("5 min ago", ago("20261022-152614-9.jsonl", 1792682774 + 300, &b));
    try std.testing.expectEqualStrings("3 h ago", ago("20261022-152614-9.jsonl", 1792682774 + 3 * 3600 + 5, &b));
    try std.testing.expectEqualStrings("2 d ago", ago("20261022-152614-9.jsonl", 1792682774 + 2 * 86400, &b));
    try std.testing.expectEqualStrings("31 d ago", ago("20260101-000000-1.jsonl", 1767225600 + 31 * 86400, &b));
}

/// Sessions started in `cwd`, newest first (at most out.len).
pub fn list(cwd: []const u8, out: []Entry) []Entry {
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return out[0..0];
    const dfd = sys.open(d, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return out[0..0];
    defer sys.close(dfd);
    var n: usize = 0;
    var b: [8192]u8 align(8) = undefined;
    while (true) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
        if (got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            off += e.reclen;
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off - e.reclen + @offsetOf(linux.dirent64, "name")])), 0);
            if (!std.mem.endsWith(u8, name, ".jsonl") or name.len > 64) continue;
            var ent = Entry{};
            if (!describe(d, name, cwd, &ent)) continue;
            // keep the newest out.len, sorted by name (time) descending
            var i: usize = n;
            while (i > 0 and std.mem.order(u8, out[i - 1].file(), name) == .lt) : (i -= 1) {
                if (i < out.len) out[i] = out[i - 1];
            }
            if (i < out.len) {
                out[i] = ent;
                if (n < out.len) n += 1;
            }
        }
    }
    return out[0..n];
}

/// Fill `e` if session file `name` was started in `cwd` and has a user prompt.
fn describe(d: []const u8, name: []const u8, cwd: []const u8, e: *Entry) bool {
    var pb: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ d, name }) catch return false;
    var fb: [16384]u8 = undefined;
    const text = sys.readFile(p, &fb) catch return false;
    var it = std.mem.splitScalar(u8, text, '\n');
    const meta = it.next() orelse return false;
    // awl writes these lines itself: match the escaped cwd instead of parsing JSON
    var cw = Buf.init(cwd.len * 6 + 16);
    defer cw.free();
    cw.add(",\"cwd\":");
    @import("buf.zig").str(&cw, cwd);
    cw.byte('}');
    if (!std.mem.endsWith(u8, meta, cw.items())) return false;
    const pre = "{\"role\":\"user\",\"content\":\"";
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, pre)) continue;
        var c = unescape(line[pre.len..], &e.first);
        if (std.mem.startsWith(u8, c, "[")) { // skip a leading [note] from /undo, /mode or !cmd
            if (std.mem.indexOf(u8, line, "]\\n\\n")) |k| c = unescape(line[k + 5 ..], &e.first);
        }
        e.first_n = c.len;
        @memcpy(e.name[0..name.len], name);
        e.name_n = name.len;
        return true;
    }
    return false;
}

/// The start of a JSON string body as one line of text (escapes decoded, cut to `out`).
fn unescape(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (i += 1) {
        var c = s[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < s.len) {
            i += 1;
            c = switch (s[i]) {
                'n', 't', 'r' => ' ',
                'u' => blk: {
                    i += 4;
                    break :blk '?';
                },
                else => s[i],
            };
        }
        if (n == 0 and c == ' ') continue;
        out[n] = c;
        n += 1;
    }
    while (n > 0 and n == out.len and (out[n - 1] & 0xC0) == 0x80) n -= 1; // whole utf-8 chars
    while (n > 0 and (out[n - 1] & 0xC0) == 0xC0) n -= 1; // a cut lead byte
    return out[0..n];
}

pub fn pathOf(e: *const Entry, out: []u8) ?[]const u8 {
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return null;
    return std.fmt.bufPrint(out, "{s}/{s}", .{ d, e.file() }) catch null;
}

/// Prompt history shared by all sessions: entries end with a 0 byte.
fn historyPath(buf: []u8) ?[]const u8 {
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/history", .{d[0 .. d.len - "/sessions".len]}) catch null;
}

/// Load the newest history (up to 256 KB, whole entries) into `out`.
pub fn loadHistory(out: *Buf) void {
    var pb: [512]u8 = undefined;
    const p = historyPath(&pb) orelse return;
    const f = sys.open(p, .{ .CLOEXEC = true }, 0) catch return;
    defer sys.close(f);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(f, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) != .SUCCESS) return;
    const keep: u64 = 256 << 10;
    const from = st.size -| keep;
    const dst = out.extend(@intCast(st.size - from));
    var got: usize = 0;
    while (got < dst.len) {
        const n = sys.check(linux.pread(f, dst[got..].ptr, dst.len - got, @intCast(from + got))) catch break;
        if (n == 0) break;
        got += n;
    }
    out.truncate(out.len - (dst.len - got));
    if (from > 0) { // drop the partial first entry
        const items = out.items();
        const z = std.mem.indexOfScalar(u8, items, 0) orelse return out.truncate(0);
        std.mem.copyForwards(u8, items[0 .. items.len - z - 1], items[z + 1 ..]);
        out.truncate(items.len - z - 1);
    }
    if (out.len > 0 and out.items()[out.len - 1] != 0) out.byte(0);
}

pub fn appendHistory(entry: []const u8) void {
    var pb: [512]u8 = undefined;
    const p = historyPath(&pb) orelse return;
    const f = sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch return;
    defer sys.close(f);
    var b = Buf.init(entry.len + 1);
    defer b.free();
    b.add(entry);
    b.byte(0);
    sys.writeAll(f, b.items()) catch {};
}

/// Stop writing to the current session file.
pub fn close() void {
    @import("agents.zig").end();
    if (fd >= 0) sys.close(fd);
    fd = -1;
    path = "";
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
