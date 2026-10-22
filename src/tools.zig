//! The tools: read, write, edit, bash, todo, grep (ripgrep), find (fd).
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const http = @import("http.zig");
const bufm = @import("buf.zig");
const Buf = bufm.Buf;
const ui = @import("ui.zig");

pub const out_cap = 64 * 1024;
pub var have_rg = false;
pub var have_fd = false;
const rg_path = "/usr/bin/rg";
const fd_path = "/usr/bin/fd";

pub fn detect() void {
    have_rg = sys.exists(rg_path);
    have_fd = sys.exists(fd_path);
}

const schema_core =
    \\{"type":"function","function":{"name":"read","description":"Read a text file. Returns numbered lines. For large files, grep for what you need first, then read with offset/limit (1-based).","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file with the given content. Creates parent directories.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Replace exact text in a file. One change: old_string + new_string. Several changes in one file: edits, a list of {old_string, new_string}, each matched against the file as it was before this call; all apply or none do. Each old_string must occur exactly once; include enough context. Read the file first.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["old_string","new_string"]}}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"bash","description":"Run a bash command in the working directory. Returns stdout+stderr and exit code. Default timeout 120 s.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","description":"seconds"},"background":{"type":"boolean","description":"start it and return at once (servers, watchers, long test runs); output goes to a log file"}},"required":["command"]}}},
    \\{"type":"function","function":{"name":"todo","description":"Checklist for long tasks with several distinct steps; skip it for quick fixes. Send the whole list every time. status: pending, doing, done or skip (put the reason in text). Keep exactly one item doing. The latest list always stays in context.","parameters":{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"text":{"type":"string"},"status":{"type":"string","enum":["pending","doing","done","skip"]}},"required":["text","status"]}}},"required":["items"]}}}
;
const schema_grep =
    \\,{"type":"function","function":{"name":"grep","description":"Search file contents with ripgrep (regex, smart case, respects .gitignore). Returns path:line:text, with path-line-text for context lines. Find several names in one call with alternatives (a|b|c), and set context to see the surrounding lines instead of reading the file separately.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string","description":"e.g. *.zig"},"context":{"type":"integer","description":"lines before and after each match (0-20)"},"ignore_case":{"type":"boolean"},"limit":{"type":"integer","description":"max output lines (default 200)"}},"required":["pattern"]}}}
;
const schema_find =
    \\,{"type":"function","function":{"name":"find","description":"List files with fd (regex on file name, respects .gitignore). No pattern lists everything.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}}}}}
;

pub fn schema(out: *Buf) void {
    out.add(schema_core);
    if (have_rg) out.add(schema_grep);
    if (have_fd) out.add(schema_find);
}

pub fn names() []const u8 {
    if (have_rg and have_fd) return "read, write, edit, bash, todo, grep, find";
    if (have_rg) return "read, write, edit, bash, todo, grep";
    if (have_fd) return "read, write, edit, bash, todo, find";
    return "read, write, edit, bash, todo";
}

// Argument parsing scratch: a reserved region, reset after each tool call.
var arg_region = Buf.init(512 << 20);
var arg_fba: std.heap.FixedBufferAllocator = undefined;
fn argAlloc() std.mem.Allocator {
    if (arg_region.base == null) _ = arg_region.extend(0);
    arg_fba = std.heap.FixedBufferAllocator.init(arg_region.base.?[0..arg_region.cap]);
    return arg_fba.allocator();
}
fn argFree() void {
    arg_region.len = arg_fba.end_index;
    arg_region.reset();
}

pub const Result = struct { ok: bool, summary: [160]u8 = undefined, summary_n: usize = 0 };

/// Record a one-line summary of the call and show it before the tool runs.
fn sum(r: *Result, name: []const u8, comptime f: []const u8, a: anytype) void {
    const s = std.fmt.bufPrint(&r.summary, f, a) catch r.summary[0..];
    r.summary_n = s.len;
    for (r.summary[0..r.summary_n]) |*c| if (c.* == '\n') {
        c.* = ' ';
    };
    ui.tool(name, r.summary[0..r.summary_n]);
}

/// Run tool `name` with JSON `args`. Output text goes to `out` (bounded).
pub fn run(name: []const u8, args: []const u8, out: *Buf) error{Cancel}!Result {
    defer argFree();
    reapJobs(out);
    const a = argAlloc();
    var r = Result{ .ok = false };
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
    const eq = std.mem.eql;
    if (eq(u8, name, "read")) {
        const p = std.json.parseFromSliceLeaky(struct { path: []const u8, offset: ?usize = null, limit: ?usize = null }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s}", .{p.path});
        r.ok = read(p.path, p.offset orelse 1, p.limit orelse 2000, out);
    } else if (eq(u8, name, "write")) {
        const p = std.json.parseFromSliceLeaky(struct { path: []const u8, content: []const u8 }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s} ({d} lines)", .{ p.path, std.mem.count(u8, p.content, "\n") + @intFromBool(p.content.len > 0 and p.content[p.content.len - 1] != '\n') });
        r.ok = write(p.path, &.{p.content}, out);
        if (r.ok) out.print("wrote {d} bytes to {s}", .{ p.content.len, p.path });
    } else if (eq(u8, name, "edit")) {
        const E = struct { old_string: ?[]const u8 = null, new_string: ?[]const u8 = null, old: ?[]const u8 = null, new: ?[]const u8 = null };
        const p = std.json.parseFromSliceLeaky(struct { path: []const u8, old_string: ?[]const u8 = null, new_string: ?[]const u8 = null, old: ?[]const u8 = null, new: ?[]const u8 = null, edits: ?[]const E = null }, a, args, opts) catch return badArgs(out, name, &r);
        var pairs: [max_edits]Pair = undefined;
        var n: usize = 0;
        if (p.old_string orelse p.old) |old| {
            pairs[0] = .{ .old = old, .new = p.new_string orelse p.new orelse return badArgs(out, name, &r) };
            n = 1;
        }
        for (p.edits orelse &.{}) |e| {
            if (n == max_edits) {
                out.print("too many edits in one call (max {d}); split them", .{max_edits});
                sum(&r, name, "{s}", .{p.path});
                return r;
            }
            pairs[n] = .{ .old = e.old_string orelse e.old orelse return badArgs(out, name, &r), .new = e.new_string orelse e.new orelse return badArgs(out, name, &r) };
            n += 1;
        }
        if (n == 0) return badArgs(out, name, &r);
        if (n == 1) sum(&r, name, "{s}", .{p.path}) else sum(&r, name, "{s} ({d} changes)", .{ p.path, n });
        r.ok = editFile(p.path, pairs[0..n], out);
    } else if (eq(u8, name, "todo")) {
        const p = std.json.parseFromSliceLeaky(struct { items: []const struct { text: []const u8, status: []const u8 = "pending" } }, a, args, opts) catch return badArgs(out, name, &r);
        var done: usize = 0;
        for (p.items) |it| done += @intFromBool(eq(u8, it.status, "done") or eq(u8, it.status, "skip"));
        sum(&r, name, "{d}/{d} done", .{ done, p.items.len });
        r.ok = todo(p.items, out);
    } else if (eq(u8, name, "bash")) {
        const p = std.json.parseFromSliceLeaky(struct { command: []const u8, timeout: ?u32 = null, background: bool = false }, a, args, opts) catch return badArgs(out, name, &r);
        if (p.background) sum(&r, name, "&{s}", .{p.command}) else sum(&r, name, "{s}", .{p.command});
        const cmd = a.dupeZ(u8, p.command) catch return badArgs(out, name, &r);
        if (p.background) {
            r.ok = startJob(cmd, out);
            return r;
        }
        const argv = [_:null]?[*:0]const u8{ "/bin/bash", "-c", cmd };
        r.ok = try spawn(&argv, @as(u64, p.timeout orelse 120) * 1000, out, .bash);
    } else if (eq(u8, name, "grep") and have_rg) {
        const p = std.json.parseFromSliceLeaky(struct { pattern: []const u8, path: ?[]const u8 = null, glob: ?[]const u8 = null, context: ?u8 = null, ignore_case: bool = false, limit: ?usize = null }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s} {s}", .{ p.pattern, p.path orelse "." });
        var argv: [24:null]?[*:0]const u8 = .{ rg_path, "-n", "--no-heading", "--color", "never", "--smart-case", "--max-columns", "300", "--max-columns-preview" } ++ .{null} ** 15;
        var n: usize = 9;
        if (p.glob) |g| {
            argv[n] = "-g";
            argv[n + 1] = a.dupeZ(u8, g) catch return badArgs(out, name, &r);
            n += 2;
        }
        if (p.context) |c| if (c > 0) {
            var cb: [8]u8 = undefined;
            argv[n] = "-C";
            argv[n + 1] = a.dupeZ(u8, std.fmt.bufPrint(&cb, "{d}", .{@min(c, 20)}) catch "2") catch return badArgs(out, name, &r);
            n += 2;
        };
        if (p.ignore_case) {
            argv[n] = "-i";
            n += 1;
        }
        argv[n] = "-e";
        argv[n + 1] = a.dupeZ(u8, p.pattern) catch return badArgs(out, name, &r);
        argv[n + 2] = "--";
        argv[n + 3] = a.dupeZ(u8, p.path orelse ".") catch return badArgs(out, name, &r);
        r.ok = try spawn(&argv, 30_000, out, .grep);
        capLines(out, @min(p.limit orelse 200, 1000), "lines");
    } else if (eq(u8, name, "find") and have_fd) {
        const p = std.json.parseFromSliceLeaky(struct { pattern: ?[]const u8 = null, path: ?[]const u8 = null }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s} {s}", .{ p.pattern orelse "*", p.path orelse "." });
        var argv: [8:null]?[*:0]const u8 = .{ fd_path, "--color", "never", "--max-results", "501" } ++ .{null} ** 3;
        argv[5] = a.dupeZ(u8, p.pattern orelse "") catch return badArgs(out, name, &r);
        argv[6] = a.dupeZ(u8, p.path orelse ".") catch return badArgs(out, name, &r);
        r.ok = try spawn(&argv, 30_000, out, .find);
        capLines(out, 500, "entries");
    } else {
        out.print("unknown tool: {s}", .{name});
        sum(&r, name, "?", .{});
    }
    return r;
}

fn badArgs(out: *Buf, name: []const u8, r: *Result) Result {
    out.print("invalid arguments for {s}; check the required fields", .{name});
    r.ok = false;
    return r.*;
}

fn errMsg(out: *Buf, what: []const u8, path: []const u8, e: anyerror) bool {
    out.print("{s} {s}: {s}", .{ what, path, switch (e) {
        error.NotFound => "no such file or directory",
        error.Access => "permission denied",
        error.IsDir => "is a directory",
        else => @tagName(sys.last_errno),
    } });
    return false;
}

const Map = struct {
    bytes: []const u8,
    fn deinit(m: Map) void {
        if (m.bytes.len > 0) _ = linux.munmap(@ptrCast(@constCast(m.bytes.ptr)), m.bytes.len);
    }
};

fn mapFile(path: []const u8) !Map {
    const fd = try sys.open(path, .{ .CLOEXEC = true }, 0);
    defer sys.close(fd);
    var st: linux.Statx = undefined;
    _ = try sys.check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .TYPE = true }, &st));
    if (linux.S.ISDIR(st.mode)) return error.IsDir;
    if (st.size == 0) return .{ .bytes = &.{} };
    const rc = try sys.check(linux.mmap(null, st.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0));
    return .{ .bytes = @as([*]const u8, @ptrFromInt(rc))[0..st.size] };
}

fn read(path: []const u8, offset: usize, limit: usize, out: *Buf) bool {
    const m = mapFile(path) catch |e| return errMsg(out, "read", path, e);
    defer m.deinit();
    const b = m.bytes;
    if (b.len == 0) {
        out.add("(empty file)");
        return true;
    }
    if (std.mem.indexOfScalar(u8, b[0..@min(b.len, 8192)], 0) != null) {
        out.print("(binary file, {d} bytes)", .{b.len});
        return true;
    }
    var it = std.mem.splitScalar(u8, b, '\n');
    var ln: usize = 0;
    var shown: usize = 0;
    const start = @max(offset, 1);
    const max = @min(limit, 2000);
    var last: usize = 0;
    while (it.next()) |line0| {
        ln += 1;
        if (it.index == null and line0.len == 0) {
            ln -= 1;
            break;
        }
        if (ln < start) continue;
        if (shown == max or out.len + line0.len + 16 > out_cap) continue;
        out.print("{d:>6}\t", .{ln});
        const line = std.mem.trimEnd(u8, line0, "\r");
        if (line.len > 2000) {
            out.add(line[0..2000]);
            out.add("…");
        } else out.add(line);
        out.byte('\n');
        shown += 1;
        last = ln;
    }
    if (start > ln) {
        out.print("offset {d} is past the end ({d} lines)", .{ start, ln });
        return false;
    }
    if (last < ln) out.print("[lines {d}-{d} of {d}; use offset={d} to continue]", .{ start, last, ln, last + 1 });
    return true;
}

fn mkdirs(path: []const u8) void {
    var pb: [4096]u8 = undefined;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        _ = linux.mkdirat(linux.AT.FDCWD, sys.z(&pb, path[0..i]), 0o755);
    }
}

/// Atomic write: temp file in the same directory, then rename over the target.
fn write(path: []const u8, parts: []const []const u8, out: *Buf) bool {
    mkdirs(path);
    var tb: [4096]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.awl-{d}", .{ path, linux.getpid() }) catch return errMsg(out, "write", path, error.Sys);
    var mode: linux.mode_t = 0o644;
    var pb: [4096]u8 = undefined;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, sys.z(&pb, path), 0, .{ .MODE = true }, &st)) == .SUCCESS) mode = st.mode & 0o7777;
    const fd = sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode) catch |e| return errMsg(out, "write", path, e);
    var ok = true;
    for (parts) |p| sys.writeAll(fd, p) catch {
        ok = false;
    };
    sys.close(fd);
    var tz: [4096]u8 = undefined;
    if (ok) ok = linux.errno(linux.renameat(linux.AT.FDCWD, sys.z(&tz, tmp), linux.AT.FDCWD, sys.z(&pb, path))) == .SUCCESS;
    if (!ok) {
        _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&tz, tmp), 0);
        return errMsg(out, "write", path, error.Sys);
    }
    return true;
}

/// Results start with this; context elision keeps every message that carries it.
pub const todo_marker = "Checklist (current):";

fn todo(items: anytype, out: *Buf) bool {
    if (items.len > 50) {
        out.add("too many items (max 50); group them");
        return false;
    }
    for (items) |it| {
        const known = for ([_][]const u8{ "pending", "doing", "done", "skip" }) |k| {
            if (std.mem.eql(u8, it.status, k)) break true;
        } else false;
        if (!known) {
            out.print("unknown status \"{s}\" for \"{s}\"; use pending, doing, done or skip", .{ it.status, it.text });
            return false;
        }
    }
    out.add(todo_marker);
    var done: usize = 0;
    for (items) |it| {
        const eq = std.mem.eql;
        const mark: []const u8 = if (eq(u8, it.status, "done")) "[x]" else if (eq(u8, it.status, "doing")) "[>]" else if (eq(u8, it.status, "skip")) "[-]" else "[ ]";
        done += @intFromBool(eq(u8, it.status, "done") or eq(u8, it.status, "skip"));
        out.print("\n{s} {s}", .{ mark, it.text });
    }
    out.print("\n({d}/{d} done)", .{ done, items.len });
    return true;
}

const max_edits = 64;
const Pair = struct { old: []const u8, new: []const u8 };

fn edit(path: []const u8, old: []const u8, new: []const u8, out: *Buf) bool {
    return editFile(path, &.{.{ .old = old, .new = new }}, out);
}

fn editFile(path: []const u8, pairs: []const Pair, out: *Buf) bool {
    for (pairs, 0..) |p, k| if (p.old.len == 0) {
        editLabel(k, pairs.len, out);
        out.add("old_string is empty; use write to create a file");
        return false;
    };
    const m = mapFile(path) catch |e| return errMsg(out, "edit", path, e);
    defer m.deinit();
    // CRLF files: models write \n; match and replace in the file's own line endings.
    var conv = Buf.init(1 << 30);
    defer conv.free();
    var fixed: [max_edits]Pair = undefined;
    const crlf = std.mem.indexOf(u8, m.bytes, "\r\n") != null;
    for (pairs, 0..) |p, k| {
        fixed[k] = p;
        if (crlf and std.mem.indexOf(u8, m.bytes, p.old) == null) {
            const o0 = conv.len;
            toCrlf(p.old, &conv);
            const n0 = conv.len;
            toCrlf(p.new, &conv);
            fixed[k] = .{ .old = conv.items()[o0..n0], .new = conv.items()[n0..] };
        }
    }
    return editIn(path, m.bytes, fixed[0..pairs.len], out);
}

fn toCrlf(s: []const u8, out: *Buf) void {
    for (s, 0..) |c, i| {
        if (c == '\n' and (i == 0 or s[i - 1] != '\r')) out.byte('\r');
        out.byte(c);
    }
}

fn editLabel(k: usize, n: usize, out: *Buf) void {
    if (n > 1) out.print("edit {d} of {d}: ", .{ k + 1, n });
}

/// Apply every pair to `bytes` (each matched in the original text) and write the file once.
/// All or nothing: a missing, ambiguous or overlapping old_string writes nothing.
fn editIn(path: []const u8, bytes: []const u8, pairs: []const Pair, out: *Buf) bool {
    var at: [max_edits]usize = undefined; // match offset per pair
    for (pairs, 0..) |p, k| {
        const i = std.mem.indexOf(u8, bytes, p.old) orelse {
            editLabel(k, pairs.len, out);
            out.print("old_string not found in {s}.", .{path});
            if (!closestLine(bytes, p.old, out)) out.add(" Read the file and copy the text exactly, including whitespace.");
            if (pairs.len > 1) out.add(" No changes were made.");
            return false;
        };
        if (std.mem.indexOfPos(u8, bytes, i + 1, p.old) != null) {
            editLabel(k, pairs.len, out);
            out.print("old_string matches {d} places in {s}. Add surrounding lines to make it unique.", .{ std.mem.count(u8, bytes, p.old), path });
            if (pairs.len > 1) out.add(" No changes were made.");
            return false;
        }
        at[k] = i;
    }
    // Order by position (insertion sort; n <= 64) and reject overlaps.
    var ord: [max_edits]usize = undefined;
    for (0..pairs.len) |k| {
        var j = k;
        while (j > 0 and at[ord[j - 1]] > at[k]) : (j -= 1) ord[j] = ord[j - 1];
        ord[j] = k;
    }
    for (1..pairs.len) |j| {
        const a = ord[j - 1];
        const b = ord[j];
        if (at[a] + pairs[a].old.len > at[b]) {
            out.print("edits {d} and {d} overlap in {s}; merge them into one edit. No changes were made.", .{ @min(a, b) + 1, @max(a, b) + 1, path });
            return false;
        }
    }
    var segs: [2 * max_edits + 1][]const u8 = undefined;
    var ns: usize = 0;
    var pos: usize = 0;
    for (ord[0..pairs.len]) |k| {
        segs[ns] = bytes[pos..at[k]];
        segs[ns + 1] = pairs[k].new;
        ns += 2;
        pos = at[k] + pairs[k].old.len;
    }
    segs[ns] = bytes[pos..];
    if (!write(path, segs[0 .. ns + 1], out)) return false;
    var minus: usize = 0;
    var plus: usize = 0;
    for (pairs) |p| {
        minus += std.mem.count(u8, p.old, "\n") + 1;
        plus += std.mem.count(u8, p.new, "\n") + 1;
    }
    if (pairs.len == 1) {
        out.print("edited {s} at line {d} (-{d} +{d} lines)", .{ path, std.mem.count(u8, bytes[0..at[0]], "\n") + 1, minus, plus });
        return true;
    }
    out.print("edited {s}: {d} changes at lines ", .{ path, pairs.len });
    for (ord[0..pairs.len], 0..) |k, j| out.print("{s}{d}", .{ if (j == 0) "" else ", ", std.mem.count(u8, bytes[0..at[k]], "\n") + 1 });
    out.print(" (-{d} +{d} lines)", .{ minus, plus });
    return true;
}

/// Point out the file line that best matches the first non-blank line of `old`:
/// trimmed equality wins, else the longest common prefix of at least 8 bytes.
/// One pass over `bytes`, no allocation. False when nothing useful was found.
fn closestLine(bytes: []const u8, old: []const u8, out: *Buf) bool {
    const want = blk: {
        var it = std.mem.splitScalar(u8, old, '\n');
        while (it.next()) |l| {
            const s = std.mem.trim(u8, l, " \t\r");
            if (s.len != 0) break :blk s;
        }
        break :blk null;
    } orelse return false;
    var best: []const u8 = &.{};
    var best_line: usize = 0;
    var best_prefix: usize = 0;
    var exact = false;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        n += 1;
        const s = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, s, want)) { // only whitespace differs
            best = std.mem.trimEnd(u8, raw, "\r");
            best_line = n;
            exact = true;
            break;
        }
        const p = commonPrefix(s, want);
        if (p >= 8 and p > best_prefix) {
            best = std.mem.trimEnd(u8, raw, "\r");
            best_line = n;
            best_prefix = p;
        }
    }
    if (!exact and best_prefix < 8) return false;
    var cut = @min(best.len, 160);
    while (cut < best.len and cut > 0 and (best[cut] & 0xC0) == 0x80) cut -= 1; // keep utf-8 whole
    out.print(" Closest line {d}: `{s}`{s}", .{ best_line, best[0..cut], if (exact) " (whitespace differs)" else "" });
    return true;
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// Keep the first `max` lines of `out`, noting how many were dropped.
fn capLines(out: *Buf, max: usize, what: []const u8) void {
    const s = out.items();
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '\n')) |j| {
        n += 1;
        i = j + 1;
        if (n == max) break;
    }
    if (n < max or i >= s.len) return;
    const total = n + std.mem.count(u8, s[i..], "\n");
    out.truncate(i);
    out.print("[{d} more {s}; narrow the search]", .{ total - n, what });
}

const Kind = enum { bash, grep, find };
// Background jobs (bash with background=true): own session, output in a log file.
const Job = struct { pid: linux.pid_t = 0, id: usize = 0, log: [96]u8 = undefined, log_n: usize = 0, cmd: [60]u8 = undefined, cmd_n: usize = 0 };
var jobs: [16]Job = [_]Job{.{}} ** 16;
var job_seq: usize = 0;

fn startJob(cmd: [*:0]const u8, out: *Buf) bool {
    const slot = for (&jobs) |*j| {
        if (j.pid == 0) break j;
    } else {
        out.add("too many background jobs (16); stop one with kill first");
        return false;
    };
    job_seq += 1;
    const path = std.fmt.bufPrint(&slot.log, "/tmp/awl-{d}-job{d}.log", .{ linux.getpid(), job_seq }) catch return false;
    const lfd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch |e| return errMsg(out, "background", path, e);
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) {
        sys.close(lfd);
        return errMsg(out, "background", "fork", error.Sys);
    }
    const pid: linux.pid_t = @intCast(pid_rc);
    if (pid == 0) {
        _ = linux.setsid(); // own session and process group: no terminal signals, one kill stops it all
        const devnull = linux.open("/dev/null", .{}, 0);
        _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.dup2(lfd, 1);
        _ = linux.dup2(lfd, 2);
        sys.unblockAll();
        var env: [1024]?[*:0]const u8 = undefined;
        const argv = [_:null]?[*:0]const u8{ "/bin/bash", "-c", cmd };
        _ = linux.execve("/bin/bash", &argv, sys.childEnvp(sys.envp, &env));
        linux.exit_group(127);
    }
    sys.close(lfd);
    const c = std.mem.span(cmd);
    slot.* = .{ .pid = pid, .id = job_seq, .log = slot.log, .log_n = path.len, .cmd_n = @min(c.len, 60) };
    @memcpy(slot.cmd[0..slot.cmd_n], c[0..slot.cmd_n]);
    out.print("started background job {d} (pid {d}); output goes to {s}. Read it with read or tail; stop it with: kill -- -{d}", .{ job_seq, pid, path, pid });
    return true;
}

/// Note finished background jobs at the top of the next tool result (and reap them).
fn reapJobs(out: *Buf) void {
    for (&jobs) |*j| {
        if (j.pid == 0) continue;
        var status: u32 = 0;
        const rc = linux.wait4(j.pid, &status, 1, null); // WNOHANG
        if (linux.errno(rc) != .SUCCESS or rc == 0) continue;
        const code: u32 = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
        out.print("[background job {d} ({s}) exited with code {d}; output in {s}]\n", .{ j.id, j.cmd[0..j.cmd_n], code, j.log[0..j.log_n] });
        j.pid = 0;
    }
}

/// Stop every background job still running (on exit): SIGTERM, then SIGKILL after ~0.5 s.
pub fn killJobs() void {
    var any = false;
    for (jobs) |j| if (j.pid != 0) {
        _ = linux.kill(-j.pid, .TERM);
        any = true;
    };
    if (!any) return;
    var tries: usize = 0;
    while (tries < 10) : (tries += 1) {
        var alive = false;
        for (&jobs) |*j| if (j.pid != 0) {
            var status: u32 = 0;
            const rc = linux.wait4(j.pid, &status, 1, null);
            if (linux.errno(rc) == .SUCCESS and rc != 0) j.pid = 0 else alive = true;
        };
        if (!alive) return;
        const ts = linux.timespec{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
    }
    for (&jobs) |*j| if (j.pid != 0) {
        _ = linux.kill(-j.pid, .KILL);
        var status: u32 = 0;
        _ = linux.wait4(j.pid, &status, 0, null);
        j.pid = 0;
    };
}

var tail_ring: [out_cap / 2]u8 = undefined;
var log_seq: usize = 0;

/// fork+execve `argv` in its own process group with stdout+stderr on one pipe.
/// Keeps the first and last 32 KB (bash: 8 KB + 12 KB, with the full output saved to a log
/// file whose path is reported when anything was cut). Timeout or Ctrl-C kills the whole group.
fn spawn(argv: [*:null]const ?[*:0]const u8, timeout_ms: u64, out: *Buf, kind: Kind) error{Cancel}!bool {
    var p: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })) != .SUCCESS) return errMsg(out, "spawn", "pipe", error.Sys);
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) {
        sys.close(p[0]);
        sys.close(p[1]);
        return errMsg(out, "spawn", "fork", error.Sys);
    }
    const pid: linux.pid_t = @intCast(pid_rc);
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        const devnull = linux.open("/dev/null", .{}, 0);
        _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.dup2(p[1], 1);
        _ = linux.dup2(p[1], 2);
        sys.unblockAll();
        var env: [1024]?[*:0]const u8 = undefined; // this desktop already has ~220 vars
        _ = linux.execve(argv[0].?, argv, sys.childEnvp(sys.envp, &env));
        linux.exit_group(127);
    }
    _ = linux.setpgid(pid, pid);
    sys.close(p[1]);
    defer sys.close(p[0]);

    const head_cap: usize = if (kind == .bash) 8 * 1024 else out_cap / 2;
    const tail_cap: usize = if (kind == .bash) 12 * 1024 else tail_ring.len;
    const base = out.len;
    // bash: tee everything into a log file; kept only if the output gets cut.
    var log_b: [96]u8 = undefined;
    var log_path: []const u8 = "";
    var log_fd: sys.fd_t = -1;
    if (kind == .bash) {
        log_seq += 1;
        log_path = std.fmt.bufPrint(&log_b, "/tmp/awl-{d}-{d}.log", .{ linux.getpid(), log_seq }) catch "";
        if (log_path.len > 0) log_fd = sys.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch -1;
    }
    var total: usize = 0;
    var dropped: usize = 0;
    var tn: usize = 0; // bytes written into tail ring (monotonic)
    const deadline = sys.nowNs() + timeout_ms * std.time.ns_per_ms;
    var timed_out = false;
    var cancelled = false;
    var chunk: [16384]u8 = undefined;
    // pidfd: notice when the command itself exits, even if a background job still holds the pipe.
    const pfd_rc = linux.pidfd_open(pid, 0);
    const pfd: i32 = if (linux.errno(pfd_rc) == .SUCCESS) @intCast(pfd_rc) else -1;
    defer if (pfd >= 0) sys.close(pfd);
    var exited = false;
    while (true) {
        const now = sys.nowNs();
        if (now >= deadline) {
            timed_out = true;
            break;
        }
        var wait_ms: i32 = @intCast(@min((deadline - now) / std.time.ns_per_ms + 1, std.math.maxInt(i32)));
        if (exited) wait_ms = 100; // after exit, drain what is already buffered, then stop
        var fds = [3]linux.pollfd{
            .{ .fd = p[0], .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = sys.sigfd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = if (exited) -1 else pfd, .events = linux.POLL.IN, .revents = 0 },
        };
        const n_ready = sys.check(linux.poll(&fds, 3, wait_ms)) catch |e| {
            if (e == error.Interrupted) continue;
            break;
        };
        if (fds[1].revents != 0) {
            sys.drainSignals();
            cancelled = true;
            break;
        }
        if (n_ready == 0) {
            if (exited) break;
            continue;
        }
        if (fds[2].revents != 0) exited = true;
        if (fds[0].revents == 0) continue;
        const n = sys.read(p[0], &chunk) catch 0;
        if (n == 0) break;
        var c = chunk[0..n];
        total += n;
        if (log_fd >= 0) sys.writeAll(log_fd, c) catch {};
        const room = head_cap -| (out.len - base);
        if (room > 0) {
            const k = @min(room, c.len);
            out.add(c[0..k]);
            c = c[k..];
        }
        for (c) |byte| {
            if (tn >= tail_cap) dropped += 1;
            tail_ring[tn % tail_cap] = byte;
            tn += 1;
        }
    }
    if (timed_out or cancelled) _ = linux.kill(-pid, .KILL);
    var status: u32 = 0;
    while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
    if (log_fd >= 0) sys.close(log_fd);
    if (tn > 0) {
        if (dropped > 0) {
            if (log_fd >= 0) {
                out.print("\n[… {d} bytes omitted; full output ({d} bytes) in {s} …]\n", .{ dropped, total, log_path });
            } else out.print("\n[… {d} bytes omitted …]\n", .{dropped});
        }
        const len = @min(tn, tail_cap);
        const start = tn - len;
        var i: usize = 0;
        while (i < len) : (i += 1) out.byte(tail_ring[(start + i) % tail_cap]);
    }
    if (log_fd >= 0 and dropped == 0) {
        var zb: [96]u8 = undefined;
        _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, log_path), 0);
    }
    if (cancelled) {
        out.add("\n[interrupted by user]");
        return error.Cancel;
    }
    if (timed_out) {
        out.print("\n[timed out after {d} s; process group killed]", .{timeout_ms / 1000});
        return false;
    }
    const code: u32 = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
    if (kind == .grep and code == 1 and out.len == base) {
        out.add("no matches");
        return true;
    }
    if (kind == .find and code == 0 and out.len == base) {
        out.add("no files found");
        return true;
    }
    if (code == 127 and out.len == base) out.add("command not found");
    if (code != 0) out.print("\n[exit {d}]", .{code});
    if (kind == .bash and code == 0 and out.len == base) out.add("(no output)");
    return code == 0;
}

// ---- tests ----
const t = std.testing;
fn tmpdir(buf: []u8) []const u8 {
    const p = std.fmt.bufPrint(buf, "/tmp/awl-test-{d}", .{linux.getpid()}) catch unreachable;
    var zb: [256]u8 = undefined;
    _ = linux.mkdirat(linux.AT.FDCWD, sys.z(&zb, p), 0o755);
    return p;
}

test "edit and read on a CRLF file" {
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/crlf.py", .{d});
    var out = Buf.init(1 << 20);
    try t.expect(write(f, &.{"def f():\r\n    return 1\r\n"}, &out));
    out.reset();
    try t.expect(edit(f, "def f():\n    return 1", "def f():\n    return 2", &out));
    out.reset();
    try t.expect(read(f, 1, 10, &out));
    try t.expectEqualStrings("     1\tdef f():\n     2\t    return 2\n", out.items());
    var fb: [64]u8 = undefined;
    try t.expectEqualStrings("def f():\r\n    return 2\r\n", try sys.readFile(f, &fb));
}

test "write, read, edit" {
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/sub/a.txt", .{d});
    var out = Buf.init(1 << 20);
    try t.expect(write(f, &.{"one\ntwo\ntwo\nthree\n"}, &out));
    out.reset();
    try t.expect(read(f, 2, 2, &out));
    try t.expectEqualStrings("     2\ttwo\n     3\ttwo\n[lines 2-3 of 4; use offset=4 to continue]", out.items());
    out.reset();
    try t.expect(!edit(f, "two", "2", &out));
    try t.expect(std.mem.indexOf(u8, out.items(), "matches 2 places") != null);
    out.reset();
    try t.expect(!edit(f, "four", "4", &out));
    out.reset();
    try t.expect(edit(f, "two\nthree", "3", &out));
    out.reset();
    try t.expect(read(f, 1, 2000, &out));
    try t.expectEqualStrings("     1\tone\n     2\ttwo\n     3\t3\n", out.items());
    out.reset();
    try t.expect(!read("/nonexistent/x", 1, 10, &out));
    try t.expectEqualStrings("read /nonexistent/x: no such file or directory", out.items());
}

test "edit: several changes in one call, all or nothing" {
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/multi.txt", .{d});
    var out = Buf.init(1 << 20);
    var fb: [256]u8 = undefined;
    try t.expect(write(f, &.{"a = 1\nb = 2\nc = 3\nd = 4\n"}, &out));
    // matched against the original text, applied in file order whatever the list order
    out.reset();
    try t.expect(editFile(f, &.{ .{ .old = "d = 4", .new = "d = 40" }, .{ .old = "a = 1", .new = "a = 10\na2 = 11" } }, &out));
    try t.expect(std.mem.startsWith(u8, out.items(), "edited /tmp/awl-test-"));
    try t.expect(std.mem.endsWith(u8, out.items(), ": 2 changes at lines 1, 4 (-2 +3 lines)"));
    try t.expectEqualStrings("a = 10\na2 = 11\nb = 2\nc = 3\nd = 40\n", try sys.readFile(f, &fb));
    // one missing old_string: nothing is written
    out.reset();
    try t.expect(!editFile(f, &.{ .{ .old = "b = 2", .new = "B" }, .{ .old = "zzzzzzzz", .new = "Z" } }, &out));
    try t.expect(std.mem.startsWith(u8, out.items(), "edit 2 of 2: old_string not found in "));
    try t.expect(std.mem.endsWith(u8, out.items(), "No changes were made."));
    try t.expectEqualStrings("a = 10\na2 = 11\nb = 2\nc = 3\nd = 40\n", try sys.readFile(f, &fb));
    // overlapping old_strings are refused
    out.reset();
    try t.expect(!editFile(f, &.{ .{ .old = "b = 2\nc", .new = "x" }, .{ .old = "c = 3", .new = "y" } }, &out));
    try t.expect(std.mem.startsWith(u8, out.items(), "edits 1 and 2 overlap in "));
    // ambiguous old_string names the edit
    out.reset();
    try t.expect(!editFile(f, &.{ .{ .old = "c = 3", .new = "C" }, .{ .old = " = ", .new = "=" } }, &out));
    try t.expect(std.mem.startsWith(u8, out.items(), "edit 2 of 2: old_string matches 5 places"));
    try t.expectEqualStrings("a = 10\na2 = 11\nb = 2\nc = 3\nd = 40\n", try sys.readFile(f, &fb));
}

test "edit: several changes on a CRLF file" {
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/multi_crlf.py", .{d});
    var out = Buf.init(1 << 20);
    var fb: [128]u8 = undefined;
    try t.expect(write(f, &.{"def f():\r\n    return 1\r\n\r\ndef g():\r\n    return 2\r\n"}, &out));
    out.reset();
    try t.expect(editFile(f, &.{ .{ .old = "def f():\n    return 1", .new = "def f():\n    return 10" }, .{ .old = "return 2", .new = "return 20" } }, &out));
    try t.expectEqualStrings("def f():\r\n    return 10\r\n\r\ndef g():\r\n    return 20\r\n", try sys.readFile(f, &fb));
}

test "edit tool call with an edits list" {
    ui.quiet = true;
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/call.txt", .{d});
    var out = Buf.init(1 << 20);
    var fb: [64]u8 = undefined;
    try t.expect(write(f, &.{"x\ny\n"}, &out));
    out.reset();
    var ab: [256]u8 = undefined;
    const args = try std.fmt.bufPrint(&ab, "{{\"path\":\"{s}\",\"edits\":[{{\"old_string\":\"x\",\"new_string\":\"X\"}},{{\"old_string\":\"y\",\"new_string\":\"Y\"}}]}}", .{f});
    const r = try run("edit", args, &out);
    try t.expect(r.ok);
    try t.expectEqualStrings("X\nY\n", try sys.readFile(f, &fb));
    try t.expect(std.mem.endsWith(u8, out.items(), ": 2 changes at lines 1, 2 (-2 +2 lines)"));
}

test "todo renders the checklist and rejects unknown statuses" {
    ui.quiet = true;
    var out = Buf.init(1 << 20);
    const r = try run("todo", "{\"items\":[{\"text\":\"read code\",\"status\":\"done\"},{\"text\":\"fix bug\",\"status\":\"doing\"},{\"text\":\"add test\",\"status\":\"pending\"},{\"text\":\"docs (skip: no public API change)\",\"status\":\"skip\"}]}", &out);
    try t.expect(r.ok);
    try t.expectEqualStrings("Checklist (current):\n[x] read code\n[>] fix bug\n[ ] add test\n[-] docs (skip: no public API change)\n(2/4 done)", out.items());
    try t.expectEqualStrings("2/4 done", r.summary[0..r.summary_n]);
    out.reset();
    const bad = try run("todo", "{\"items\":[{\"text\":\"x\",\"status\":\"maybe\"}]}", &out);
    try t.expect(!bad.ok);
    try t.expectEqualStrings("unknown status \"maybe\" for \"x\"; use pending, doing, done or skip", out.items());
}

test "grep: alternation, context, ignore_case, limit" {
    ui.quiet = true;
    detect();
    if (!have_rg) return error.SkipZigTest;
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/g/a.txt", .{d});
    var out = Buf.init(1 << 20);
    try t.expect(write(f, &.{"one\nAlpha\ntwo\nthree\nbeta\nfour\n"}, &out));
    var ab: [512]u8 = undefined;
    out.reset();
    var r = try run("grep", try std.fmt.bufPrint(&ab, "{{\"pattern\":\"alpha|beta\",\"path\":\"{s}\",\"context\":1,\"ignore_case\":true}}", .{f}), &out);
    try t.expect(r.ok);
    try t.expectEqualStrings("1-one\n2:Alpha\n3-two\n4-three\n5:beta\n6-four\n", out.items());
    out.reset();
    r = try run("grep", try std.fmt.bufPrint(&ab, "{{\"pattern\":\"o\",\"path\":\"{s}\",\"limit\":2}}", .{f}), &out);
    try t.expectEqualStrings("1:one\n3:two\n[1 more lines; narrow the search]", out.items());
}

test "background jobs: start, log, exit notice, kill on exit" {
    ui.quiet = true;
    var out = Buf.init(1 << 20);
    var r = try run("bash", "{\"command\":\"echo hi; sleep 0.2; echo bye\",\"background\":true}", &out);
    try t.expect(r.ok);
    try t.expect(std.mem.startsWith(u8, out.items(), "started background job "));
    const ps = std.mem.indexOf(u8, out.items(), "/tmp/awl-").?;
    const pe = std.mem.indexOfPos(u8, out.items(), ps, ". Read").?;
    var lp: [96]u8 = undefined;
    const log = lp[0 .. pe - ps];
    @memcpy(log, out.items()[ps..pe]);
    const ts = linux.timespec{ .sec = 0, .nsec = 600 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
    out.reset();
    r = try run("bash", "{\"command\":\"echo next\"}", &out);
    try t.expect(std.mem.startsWith(u8, out.items(), "[background job "));
    try t.expect(std.mem.indexOf(u8, out.items(), "(echo hi; sleep 0.2; echo bye) exited with code 0; output in /tmp/awl-") != null);
    try t.expect(std.mem.endsWith(u8, out.items(), "]\nnext\n"));
    var lb: [64]u8 = undefined;
    try t.expectEqualStrings("hi\nbye\n", try sys.readFile(log, &lb));
    var zb: [128]u8 = undefined;
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, log), 0);
    // a long job is stopped by killJobs (what main does on exit)
    out.reset();
    r = try run("bash", "{\"command\":\"sleep 30\",\"background\":true}", &out);
    try t.expect(r.ok);
    var pid: linux.pid_t = 0;
    for (jobs) |j| if (j.pid != 0) {
        pid = j.pid;
    };
    try t.expect(pid != 0);
    const t0 = sys.nowNs();
    killJobs();
    try t.expect(sys.nowNs() - t0 < 1 * std.time.ns_per_s);
    try t.expect(linux.errno(linux.kill(pid, @enumFromInt(0))) == .SRCH);
    const pe2 = std.mem.indexOf(u8, out.items(), ". Read").?;
    const ps2 = std.mem.indexOf(u8, out.items(), "/tmp/awl-").?;
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, out.items()[ps2..pe2]), 0);
}

test "edit: not-found hint when only whitespace differs" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "fn main() {\n    const x = foo(1);\n}\n", &.{.{ .old = "\tconst x = foo(1);", .new = "" }}, &out));
    try t.expectEqualStrings(
        "old_string not found in src/a.zig. Closest line 2: `    const x = foo(1);` (whitespace differs)",
        out.items(),
    );
}

test "edit: not-found hint on a near miss" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "pub fn readFile(path: []const u8) void\n", &.{.{ .old = "pub fn readFile(path: []const u8, n: usize) void", .new = "" }}, &out));
    try t.expectEqualStrings(
        "old_string not found in src/a.zig. Closest line 1: `pub fn readFile(path: []const u8) void`",
        out.items(),
    );
}

test "edit: long closest line is cut on a utf-8 boundary" {
    var out = Buf.init(1 << 20);
    const line = "x" ** 159 ++ "é and more";
    try t.expect(!editIn("a", line ++ "\n", &.{.{ .old = "x" ** 20 ++ "y", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in a. Closest line 1: `" ++ "x" ** 159 ++ "`", out.items());
}

test "edit: no hint without a useful match" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "const a = 1;\nconst b = 2;\n", &.{.{ .old = "zzzzzzzzzzzz", .new = "" }}, &out));
    try t.expectEqualStrings(
        "old_string not found in src/a.zig. Read the file and copy the text exactly, including whitespace.",
        out.items(),
    );
}

test "spawn returns when the command exits even if a background job holds the pipe" {
    var out = Buf.init(1 << 20);
    const t0 = sys.nowNs();
    const a = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "sleep 5 & echo started" };
    try t.expect(try spawn(&a, 10_000, &out, .bash));
    try t.expect(sys.nowNs() - t0 < 2 * std.time.ns_per_s);
    try t.expectEqualStrings("started\n", out.items());
}

test "spawn: output, exit code, truncation, timeout kills grandchild" {
    var out = Buf.init(1 << 20);
    const a1 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "echo hi; exit 3" };
    try t.expect(!try spawn(&a1, 5000, &out, .bash));
    try t.expectEqualStrings("hi\n\n[exit 3]", out.items());
    out.reset();
    const a2 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "head -c 200000 /dev/zero | tr '\\0' x" };
    try t.expect(try spawn(&a2, 5000, &out, .bash));
    try t.expect(out.len < 21 * 1024 + 200);
    const omit = std.mem.indexOf(u8, out.items(), "bytes omitted; full output (200000 bytes) in /tmp/awl-") orelse return error.TestUnexpectedResult;
    const pstart = std.mem.indexOfPos(u8, out.items(), omit, "/tmp/awl-").?;
    const pend = std.mem.indexOfPos(u8, out.items(), pstart, " …]").?;
    var lb: [256 * 1024]u8 = undefined;
    try t.expectEqual(@as(usize, 200000), (try sys.readFile(out.items()[pstart..pend], &lb)).len);
    var zb: [128]u8 = undefined;
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, out.items()[pstart..pend]), 0);
    out.reset();
    const a_small = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "echo small" };
    try t.expect(try spawn(&a_small, 5000, &out, .bash));
    try t.expectEqualStrings("small\n", out.items()); // short output: no log file mentioned
    out.reset();
    const t0 = sys.nowNs();
    const a3 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "(sleep 30; echo leaked) & sleep 30" };
    try t.expect(!try spawn(&a3, 300, &out, .bash));
    try t.expect(sys.nowNs() - t0 < 2 * std.time.ns_per_s);
    try t.expect(std.mem.indexOf(u8, out.items(), "timed out") != null);
}
