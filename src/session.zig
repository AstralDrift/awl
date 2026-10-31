//! Sessions: one JSON message per line in ~/.local/state/awl/sessions/<utc>.jsonl.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const bufm = @import("buf.zig");
const Buf = bufm.Buf;
const Str = @import("jint.zig").Str;

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
    lines = 0;
    viewReset();
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

/// Lines in the session file: the next record is line `lines + 1`. A line's number never
/// changes (the file is append-only), so the model and the view can cite it.
pub var lines: u32 = 0;

/// One write per record, newline included: a crash can tear only the last line, never glue two.
pub fn append(json: []const u8) void {
    if (fd < 0) return;
    const iov = [_]std.posix.iovec_const{ .{ .base = json.ptr, .len = json.len }, .{ .base = "\n", .len = 1 } };
    const want = json.len + 1;
    const rc = linux.writev(fd, &iov, 2);
    if (linux.errno(rc) == .SUCCESS and rc < want) { // short write (disk full, signal): finish it
        if (rc < json.len) sys.writeAll(fd, json[rc..]) catch {};
        sys.writeAll(fd, "\n") catch {};
    }
    lines += 1;
}

/// Where a message is: its line in the session file, and its body in the view (first line, line count). 0 = none.
pub const Rec = struct { n: u32 = 0, at: u32 = 0, len: u32 = 0 };

/// What the view shows of a message: role, text, the calls an assistant made, the call a tool result answers.
pub const Call = struct { name: []const u8, args: []const u8 };
pub const Msg = struct { role: []const u8, text: []const u8, calls: []const Call = &.{}, of: ?Call = null };

/// Append a message to the session file and the view.
pub fn record(json: []const u8, m: Msg) Rec {
    if (fd < 0) return .{};
    append(json);
    var r = viewAdd(lines, m);
    r.n = lines;
    return r;
}

/// Append a message given only as JSON (parsed for the view).
pub fn recordJson(json: []const u8) Rec {
    if (fd < 0) return .{};
    append(json);
    var p = Parser.init();
    defer p.deinit();
    var r = if (p.msg(json)) |m| viewAdd(lines, m) else Rec{};
    r.n = lines;
    return r;
}

// ---- the view: the session as plain text the model can grep and read ----
// One per awl process (<sessions>/view-<pid>.txt), rewritten in place when the session
// changes, so the sandbox can mount this one file read-only for the whole run. Each message
// starts with a line {"n":<line in the session file>,"role":…} and its text follows as is.
// Reasoning is left out (it is in the session file): it would bury the grep hits.

var view_fd: sys.fd_t = -1;
var view_b: [512]u8 = undefined;
pub var view_path: []const u8 = "";
pub var view_lines: u32 = 0;

/// Create the view, or empty it in place (same file: a sandbox mount of it stays valid).
fn viewReset() void {
    view_lines = 0;
    if (view_fd >= 0) {
        _ = linux.ftruncate(view_fd, 0);
        return;
    }
    var db: [400]u8 = undefined;
    const d = dir(&db) orelse return;
    mkdirs(d);
    pruneViews(d);
    view_path = std.fmt.bufPrint(&view_b, "{s}/view-{d}.txt", .{ d, linux.getpid() }) catch return;
    view_fd = sys.open(view_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch -1;
    if (view_fd < 0) view_path = "";
}

/// At exit: the view is a copy, the session file stays.
pub fn dropView() void {
    if (view_fd < 0) return;
    sys.close(view_fd);
    view_fd = -1;
    var zb: [520]u8 = undefined;
    _ = linux.unlink(sys.z(&zb, view_path));
    view_path = "";
}

/// Views left by awl processes that were killed.
fn pruneViews(d: []const u8) void {
    const dfd = sys.open(d, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return;
    defer sys.close(dfd);
    var b: [8192]u8 align(8) = undefined;
    while (true) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch return;
        if (got == 0) return;
        var off: usize = 0;
        while (off < got) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off + @offsetOf(linux.dirent64, "name")])), 0);
            off += e.reclen;
            if (!std.mem.startsWith(u8, name, "view-") or !std.mem.endsWith(u8, name, ".txt")) continue;
            const pid = std.fmt.parseInt(i32, name[5 .. name.len - 4], 10) catch continue;
            if (linux.errno(linux.kill(pid, @enumFromInt(0))) != .SRCH) continue;
            var zb: [300]u8 = undefined;
            _ = linux.unlinkat(dfd, sys.z(&zb, name), 0);
        }
    }
}

fn viewAdd(n: u32, m: Msg) Rec {
    if (view_fd < 0) return .{};
    var w = Buf.init(m.text.len + m.text.len / 16 + 4096 + if (m.calls.len > 0) m.calls.len * 1024 + totalArgs(m.calls) else 0);
    defer w.free();
    w.print("{{\"n\":{d},\"role\":", .{n});
    bufm.str(&w, m.role);
    if (m.of) |c| {
        w.add(",\"call\":");
        var cb: [320]u8 = undefined;
        bufm.str(&w, callLine(c, &cb));
    }
    w.add("}\n");
    const body_start = w.len;
    defuse(&w, m.text);
    if (w.len > body_start and w.items()[w.len - 1] != '\n') w.byte('\n');
    for (m.calls) |c| {
        w.add("→ ");
        w.add(c.name);
        w.byte(' ');
        for (c.args) |ch| w.byte(if (ch == '\n' or ch == '\r') ' ' else ch);
        w.byte('\n');
    }
    const body_lines: u32 = @intCast(std.mem.count(u8, w.items()[body_start..], "\n"));
    sys.writeAll(view_fd, w.items()) catch return .{};
    const r = Rec{ .at = view_lines + 2, .len = body_lines };
    view_lines += 1 + body_lines;
    return r;
}

fn totalArgs(calls: []const Call) usize {
    var n: usize = 0;
    for (calls) |c| n += c.args.len;
    return n;
}

/// "name args" on one line, cut to fit `out` on a UTF-8 boundary.
fn callLine(c: Call, out: []u8) []const u8 {
    var n: usize = 0;
    for ([_][]const u8{ c.name, " ", c.args }) |part| for (part) |ch| {
        if (n == out.len) break;
        out[n] = if (ch == '\n' or ch == '\r') ' ' else ch;
        n += 1;
    };
    if (n == out.len) { // full: drop a character cut at the end
        var k = n;
        while (k > 0 and (out[k - 1] & 0xC0) == 0x80) k -= 1;
        if (k > 0 and k - 1 + (std.unicode.utf8ByteSequenceLength(out[k - 1]) catch 1) > n) n = k - 1;
    }
    return out[0..n];
}

/// Text as is, except a line that would read as a record header gets a leading space.
fn defuse(w: *Buf, s: []const u8) void {
    var from: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, s, at, "{\"n\":")) |i| {
        at = i + 1;
        if (i > 0 and s[i - 1] != '\n') continue;
        w.add(s[from..i]);
        w.byte(' ');
        from = i;
    }
    w.add(s[from..]);
}

/// One message line, as std.json parses it (agent's compaction transcript uses it too: one parser in the binary).
pub const Json = struct {
    role: Str,
    content: ?Str = null,
    tool_call_id: ?Str = null,
    tool_calls: ?[]const struct { id: Str = .{ .v = "" }, function: struct { name: Str = .{ .v = "" }, arguments: Str = .{ .v = "" } } = .{} } = null,
};

/// Parses session lines for the view (a reused arena; the last assistant's calls kept for its tool results).
const Parser = struct {
    region: Buf,
    fba: std.heap.FixedBufferAllocator,
    ids: [16][64]u8 = undefined,
    id_n: [16]usize = undefined,
    sums: [16][320]u8 = undefined,
    sum_n: [16]usize = undefined,
    n_calls: usize = 0,
    calls: [16]Call = undefined,

    fn init() Parser {
        var p = Parser{ .region = Buf.init(1 << 30), .fba = undefined };
        _ = p.region.extend(0);
        p.fba = std.heap.FixedBufferAllocator.init(p.region.base.?[0..p.region.cap]);
        return p;
    }
    fn deinit(p: *Parser) void {
        p.region.free();
    }

    /// The message on one session line, or null (the meta line, a torn or broken line).
    /// Slices point into the arena until the next call.
    fn msg(p: *Parser, line: []const u8) ?Msg {
        if (line.len < 2 or line[0] != '{' or std.mem.startsWith(u8, line, "{\"awl\"")) return null;
        p.fba.reset();
        const m = std.json.parseFromSliceLeaky(Json, p.fba.allocator(), line, .{ .ignore_unknown_fields = true }) catch return null;
        var out = Msg{ .role = m.role.v, .text = if (m.content) |c| c.v else "" };
        if (m.tool_calls) |tc| {
            p.n_calls = @min(tc.len, p.calls.len);
            for (tc[0..p.n_calls], 0..) |c, i| {
                const k = @min(c.id.v.len, 64);
                @memcpy(p.ids[i][0..k], c.id.v[0..k]);
                p.id_n[i] = k;
                const s = callLine(.{ .name = c.function.name.v, .args = c.function.arguments.v }, &p.sums[i]);
                p.sum_n[i] = s.len;
                p.calls[i] = .{ .name = c.function.name.v, .args = c.function.arguments.v };
            }
            out.calls = p.calls[0..p.n_calls];
        }
        if (m.tool_call_id) |id| for (0..p.n_calls) |i| if (std.mem.eql(u8, p.ids[i][0..p.id_n[i]], id.v)) {
            out.of = .{ .name = p.sums[i][0..p.sum_n[i]], .args = "" };
        };
        return out;
    }
};

/// Start a new session file holding lines 2..upto-1 of the current one (rewind): line numbers
/// and the view stay as they were. False if the current file cannot be read.
pub fn restartCopy(upto: u32) bool {
    if (path.len == 0) return false;
    var mb = Buf.init(1 << 30);
    defer mb.free();
    const f = sys.open(path, .{ .CLOEXEC = true }, 0) catch return false;
    while (true) {
        const dst = mb.extend(1 << 16);
        const n = sys.read(f, dst) catch 0;
        mb.truncate(mb.len - (dst.len - n));
        if (n == 0) break;
    }
    sys.close(f);
    restart();
    if (fd < 0) return true;
    var parser = Parser.init();
    defer parser.deinit();
    var it = std.mem.splitScalar(u8, mb.items(), '\n');
    var ln: u32 = 0;
    while (it.next()) |line| {
        ln += 1;
        if (ln == 1) continue; // the old meta line: restart wrote a new one
        if (ln >= upto) break;
        append(line);
        if (parser.msg(line)) |m| _ = viewAdd(lines, m);
    }
    return true;
}

/// Feed each message line of `p` to `onMsg`, with where it is. Reopens the file for append
/// and writes the view. A line that is not a message (meta, torn by a crash) is skipped but
/// keeps its number; a torn last line gets its newline so the next record starts clean.
pub fn load(p: []const u8, comptime onMsg: fn ([]const u8, Rec) void) !usize {
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
    viewReset();
    var parser = Parser.init();
    defer parser.deinit();
    var count: usize = 0;
    lines = 0;
    var text = mb.items();
    if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (text.len == 0) break;
        lines += 1;
        const m = parser.msg(line) orelse continue;
        var r = viewAdd(lines, m);
        r.n = lines;
        onMsg(line, r);
        count += 1;
    }
    path = path_b[0..@min(p.len, path_b.len)];
    @memcpy(@constCast(path), p[0..path.len]);
    fd = sys.open(p, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0) catch -1;
    if (fd >= 0 and mb.len > 0 and mb.items()[mb.len - 1] != '\n') sys.writeAll(fd, "\n") catch {};
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

test "view: a body line that looks like a record header is defused" {
    var w = Buf.init(4096);
    defer w.free();
    defuse(&w, "{\"n\":3,\"role\":\"user\"}\nok {\"n\":4}\n{\"n\":5}");
    try std.testing.expectEqualStrings(" {\"n\":3,\"role\":\"user\"}\nok {\"n\":4}\n {\"n\":5}", w.items());
}

test "view: a call line is one line, cut on a UTF-8 boundary" {
    var b: [12]u8 = undefined;
    try std.testing.expectEqualStrings("bash {\"a\": 1", callLine(.{ .name = "bash", .args = "{\"a\":\n1}" }, &b));
    try std.testing.expectEqualStrings("read ✓✓", callLine(.{ .name = "read", .args = "✓✓✓" }, &b)[0..11]);
    try std.testing.expectEqual(@as(usize, 11), callLine(.{ .name = "read", .args = "✓✓✓" }, &b).len);
}

test "view: session lines parse to messages; tool results name their call; torn lines are skipped" {
    var p = Parser.init();
    defer p.deinit();
    try std.testing.expect(p.msg("{\"awl\":\"0.1\",\"cwd\":\"/x\"}") == null);
    try std.testing.expect(p.msg("{\"role\":\"user\",\"content\":\"tor") == null);
    const a = p.msg("{\"role\":\"assistant\",\"content\":\"ok\",\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}").?;
    try std.testing.expectEqualStrings("assistant", a.role);
    try std.testing.expectEqual(@as(usize, 1), a.calls.len);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", a.calls[0].args);
    const t = p.msg("{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"a\\nb\"}").?;
    try std.testing.expectEqualStrings("a\nb", t.text);
    try std.testing.expectEqualStrings("bash {\"command\":\"ls\"}", t.of.?.name);
}
