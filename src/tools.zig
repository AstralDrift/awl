//! The six tools: read, write, edit, bash, grep (ripgrep), find (fd).
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
    \\{"type":"function","function":{"name":"edit","description":"Replace one exact, unique occurrence of old_string with new_string in a file. Read the file first. Include enough context to make old_string unique.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}}},
    \\{"type":"function","function":{"name":"bash","description":"Run a bash command in the working directory. Returns stdout+stderr and exit code. Default timeout 120 s.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","description":"seconds"}},"required":["command"]}}}
;
const schema_grep =
    \\,{"type":"function","function":{"name":"grep","description":"Search file contents with ripgrep (regex, smart case, respects .gitignore). Returns path:line:text.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string","description":"e.g. *.zig"}},"required":["pattern"]}}}
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
    if (have_rg and have_fd) return "read, write, edit, bash, grep, find";
    if (have_rg) return "read, write, edit, bash, grep";
    if (have_fd) return "read, write, edit, bash, find";
    return "read, write, edit, bash";
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
        const p = std.json.parseFromSliceLeaky(struct { path: []const u8, old_string: ?[]const u8 = null, new_string: ?[]const u8 = null, old: ?[]const u8 = null, new: ?[]const u8 = null }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s}", .{p.path});
        const old = p.old_string orelse p.old orelse return badArgs(out, name, &r);
        const new = p.new_string orelse p.new orelse return badArgs(out, name, &r);
        r.ok = edit(p.path, old, new, out);
    } else if (eq(u8, name, "bash")) {
        const p = std.json.parseFromSliceLeaky(struct { command: []const u8, timeout: ?u32 = null }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s}", .{p.command});
        const cmd = a.dupeZ(u8, p.command) catch return badArgs(out, name, &r);
        const argv = [_:null]?[*:0]const u8{ "/bin/bash", "-c", cmd };
        r.ok = try spawn(&argv, @as(u64, p.timeout orelse 120) * 1000, out, .bash);
    } else if (eq(u8, name, "grep") and have_rg) {
        const p = std.json.parseFromSliceLeaky(struct { pattern: []const u8, path: ?[]const u8 = null, glob: ?[]const u8 = null }, a, args, opts) catch return badArgs(out, name, &r);
        sum(&r, name, "{s} {s}", .{ p.pattern, p.path orelse "." });
        var argv: [16:null]?[*:0]const u8 = .{ rg_path, "-n", "--no-heading", "--color", "never", "--smart-case", "--max-columns", "300", "--max-columns-preview" } ++ .{null} ** 7;
        var n: usize = 9;
        if (p.glob) |g| {
            argv[n] = "-g";
            argv[n + 1] = a.dupeZ(u8, g) catch return badArgs(out, name, &r);
            n += 2;
        }
        argv[n] = "-e";
        argv[n + 1] = a.dupeZ(u8, p.pattern) catch return badArgs(out, name, &r);
        argv[n + 2] = "--";
        argv[n + 3] = a.dupeZ(u8, p.path orelse ".") catch return badArgs(out, name, &r);
        r.ok = try spawn(&argv, 30_000, out, .grep);
        capLines(out, 200, "matches");
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

fn edit(path: []const u8, old: []const u8, new: []const u8, out: *Buf) bool {
    if (old.len == 0) {
        out.add("old_string is empty; use write to create a file");
        return false;
    }
    const m = mapFile(path) catch |e| return errMsg(out, "edit", path, e);
    defer m.deinit();
    // CRLF files: models write \n; match and replace in the file's own line endings.
    var old_b = Buf.init(old.len * 2 + 16);
    var new_b = Buf.init(new.len * 2 + 16);
    defer old_b.free();
    defer new_b.free();
    if (std.mem.indexOf(u8, m.bytes, old) == null and std.mem.indexOf(u8, m.bytes, "\r\n") != null) {
        toCrlf(old, &old_b);
        toCrlf(new, &new_b);
        return editIn(path, m.bytes, old_b.items(), new_b.items(), out);
    }
    return editIn(path, m.bytes, old, new, out);
}

fn toCrlf(s: []const u8, out: *Buf) void {
    for (s, 0..) |c, i| {
        if (c == '\n' and (i == 0 or s[i - 1] != '\r')) out.byte('\r');
        out.byte(c);
    }
}

fn editIn(path: []const u8, bytes: []const u8, old: []const u8, new: []const u8, out: *Buf) bool {
    const m = struct { bytes: []const u8 }{ .bytes = bytes };
    const i = std.mem.indexOf(u8, m.bytes, old) orelse {
        out.print("old_string not found in {s}.", .{path});
        if (!closestLine(m.bytes, old, out)) out.add(" Read the file and copy the text exactly, including whitespace.");
        return false;
    };
    if (std.mem.indexOfPos(u8, m.bytes, i + 1, old) != null) {
        out.print("old_string matches {d} places in {s}. Add surrounding lines to make it unique.", .{ std.mem.count(u8, m.bytes, old), path });
        return false;
    }
    if (!write(path, &.{ m.bytes[0..i], new, m.bytes[i + old.len ..] }, out)) return false;
    const line = std.mem.count(u8, m.bytes[0..i], "\n") + 1;
    out.print("edited {s} at line {d} (-{d} +{d} lines)", .{ path, line, std.mem.count(u8, old, "\n") + 1, std.mem.count(u8, new, "\n") + 1 });
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
var tail_ring: [out_cap / 2]u8 = undefined;

/// fork+execve `argv` in its own process group with stdout+stderr on one pipe.
/// Keeps the first and last 32 KB. Timeout or Ctrl-C kills the whole group.
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

    const half = out_cap / 2;
    const base = out.len;
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
        const room = half -| (out.len - base);
        if (room > 0) {
            const k = @min(room, c.len);
            out.add(c[0..k]);
            c = c[k..];
        }
        for (c) |byte| {
            if (tn >= tail_ring.len) dropped += 1;
            tail_ring[tn % tail_ring.len] = byte;
            tn += 1;
        }
    }
    if (timed_out or cancelled) _ = linux.kill(-pid, .KILL);
    var status: u32 = 0;
    while (linux.errno(linux.wait4(pid, &status, 0, null)) == .INTR) {}
    if (tn > 0) {
        if (dropped > 0) out.print("\n[… {d} bytes omitted …]\n", .{dropped});
        const len = @min(tn, tail_ring.len);
        const start = tn - len;
        var i: usize = 0;
        while (i < len) : (i += 1) out.byte(tail_ring[(start + i) % tail_ring.len]);
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

test "edit: not-found hint when only whitespace differs" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "fn main() {\n    const x = foo(1);\n}\n", "\tconst x = foo(1);", "", &out));
    try t.expectEqualStrings(
        "old_string not found in src/a.zig. Closest line 2: `    const x = foo(1);` (whitespace differs)",
        out.items(),
    );
}

test "edit: not-found hint on a near miss" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "pub fn readFile(path: []const u8) void\n", "pub fn readFile(path: []const u8, n: usize) void", "", &out));
    try t.expectEqualStrings(
        "old_string not found in src/a.zig. Closest line 1: `pub fn readFile(path: []const u8) void`",
        out.items(),
    );
}

test "edit: long closest line is cut on a utf-8 boundary" {
    var out = Buf.init(1 << 20);
    const line = "x" ** 159 ++ "é and more";
    try t.expect(!editIn("a", line ++ "\n", "x" ** 20 ++ "y", "", &out));
    try t.expectEqualStrings("old_string not found in a. Closest line 1: `" ++ "x" ** 159 ++ "`", out.items());
}

test "edit: no hint without a useful match" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "const a = 1;\nconst b = 2;\n", "zzzzzzzzzzzz", "", &out));
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
    try t.expect(out.len < out_cap + 64);
    try t.expect(std.mem.indexOf(u8, out.items(), "bytes omitted") != null);
    out.reset();
    const t0 = sys.nowNs();
    const a3 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "(sleep 30; echo leaked) & sleep 30" };
    try t.expect(!try spawn(&a3, 300, &out, .bash));
    try t.expect(sys.nowNs() - t0 < 2 * std.time.ns_per_s);
    try t.expect(std.mem.indexOf(u8, out.items(), "timed out") != null);
}
