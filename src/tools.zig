//! The tools: read, write, edit, bash, todo, grep (ripgrep), find (fd).
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const http = @import("http.zig");
const bufm = @import("buf.zig");
const Buf = bufm.Buf;
const ui = @import("ui.zig");
const undo = @import("undo.zig");
const Int = @import("jint.zig").Int;
const Str = @import("jint.zig").Str;

fn opt(x: ?Str) ?[]const u8 {
    return if (x) |v| v.v else null;
}

/// auto: run every tool. ask: the user approves each command and file change.
/// plan: files are read-only and commands need approval (look, then propose).
pub const Mode = enum { auto, ask, plan };
pub var mode: Mode = .auto;
pub const Answer = enum { yes, no, always, cancel };
/// Set by the TUI. Without it (one-shot, pipes) ask mode allows everything.
pub var ask: ?*const fn () Answer = null;
/// What the pending question is about (a background agent shows it in the dashboard).
pub var ask_reason: []const u8 = "";
/// The command a bash call asks to run (empty for other tools): the TUI offers its prefix.
pub var ask_command: []const u8 = "";

// Command prefixes the user allowed for this session ("zig build", "cargo test").
var prefixes: [16][64]u8 = undefined;
var prefix_len: [16]usize = undefined;
var n_prefixes: usize = 0;

/// What "always allow" would cover for `cmd`: its first word, plus the second for tools whose
/// second word is a subcommand ("zig build test" → "zig build"; "echo hi" → "echo").
pub fn commandPrefix(cmd: []const u8) []const u8 {
    const c0 = std.mem.trim(u8, cmd, " \t");
    var it = std.mem.tokenizeScalar(u8, c0, ' ');
    const first = it.next() orelse return "";
    const second = it.next() orelse return first;
    const sub = [_][]const u8{ "git", "cargo", "npm", "pnpm", "yarn", "bun", "go", "zig", "docker", "podman", "kubectl", "uv", "pip", "mise", "gh", "dotnet", "mvn", "gradle", "deno", "swift", "systemctl", "just" };
    for (sub) |x| if (std.mem.eql(u8, first, x)) {
        for (second) |c| if (!(std.ascii.isLower(c) or c == '-' or c == '_')) return first;
        return c0[0 .. @intFromPtr(second.ptr) - @intFromPtr(c0.ptr) + second.len];
    };
    return first;
}

pub fn allowPrefix(p: []const u8) void {
    if (n_prefixes == prefixes.len or p.len == 0 or p.len > 64) return;
    @memcpy(prefixes[n_prefixes][0..p.len], p);
    prefix_len[n_prefixes] = p.len;
    n_prefixes += 1;
}

/// An allowed prefix covers `cmd` unless it chains, substitutes or redirects (then it asks).
fn prefixAllowed(cmd0: []const u8) bool {
    const cmd = std.mem.trim(u8, cmd0, " \t");
    if (std.mem.indexOfAny(u8, cmd, ";&|`<>\n") != null or std.mem.indexOf(u8, cmd, "$(") != null) return false;
    for (0..n_prefixes) |i| {
        const p = prefixes[i][0..prefix_len[i]];
        if (std.mem.startsWith(u8, cmd, p) and (cmd.len == p.len or cmd[p.len] == ' ')) return true;
    }
    return false;
}

test "command prefixes" {
    try std.testing.expectEqualStrings("zig build", commandPrefix("zig build test -Doptimize=ReleaseSmall"));
    try std.testing.expectEqualStrings("python3", commandPrefix("python3 calc.py"));
    try std.testing.expectEqualStrings("ls", commandPrefix("ls -la"));
    try std.testing.expectEqualStrings("make", commandPrefix("make"));
    try std.testing.expectEqualStrings("echo", commandPrefix("echo one"));
    try std.testing.expectEqualStrings("git", commandPrefix("git -C x status"));
    allowPrefix("zig build");
    defer n_prefixes = 0;
    try std.testing.expect(prefixAllowed("zig build test"));
    try std.testing.expect(!prefixAllowed("zig build && rm -rf ~"));
    try std.testing.expect(!prefixAllowed("zig buildx"));
    try std.testing.expect(!prefixAllowed("zig fmt ."));
}

/// May this file change or command run? false: refused, and `out` says why.
fn gate(name: []const u8, changes_files: bool, out: *Buf) error{Cancel}!bool {
    if (mode == .auto) return true;
    if (mode == .plan and changes_files) {
        out.add("Plan mode: files are read-only. Investigate with read, grep, find and bash, then describe the change you propose; the user will switch modes to let you make it.");
        return false;
    }
    const f = ask orelse return true;
    if (!changes_files and prefixAllowed(ask_command)) return true;
    ask_reason = if (changes_files) "change a file" else "run a command";
    switch (f()) {
        .yes => return true,
        .always => {
            if (mode == .ask) mode = .auto;
            return true;
        },
        .no => {
            out.print("The user declined this {s} call. Ask what they want, or try another way.", .{name});
            return false;
        },
        .cancel => {
            out.add("[interrupted by user]");
            return error.Cancel;
        },
    }
}

/// Snapshot `path` for /undo before it changes.
fn save(path: []const u8) void {
    if (!undo.snapshot(path)) ui.note("{s} is too large for /undo; the change goes ahead", .{path});
}

/// A command the user typed with `!`: no approval, same output limits as bash.
pub fn userShell(cmd: [:0]const u8, out: *Buf) error{Cancel}!bool {
    const argv = [_:null]?[*:0]const u8{ "/bin/bash", "-c", cmd };
    return spawn(&argv, 600_000, out, .bash, false);
}

/// The project's files for the @file picker (fd: respects .gitignore), one per line.
pub fn listFiles(out: *Buf) bool {
    if (!have_fd) return false;
    const argv = [_:null]?[*:0]const u8{ fd_path, "--type", "f", "--color", "never", "--max-results", "20000" };
    return spawn(&argv, 5_000, out, .find, false) catch false;
}

pub fn undoLast(out: *Buf) usize {
    return undo.undo(&write, out);
}

/// Rewind: put back every file change from undo turn `from` on.
pub fn undoFrom(from: u32, out: *Buf) usize {
    return undo.undoFrom(from, &write, out);
}

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
    \\{"type":"function","function":{"name":"read","description":"Read a text file. The first line shown and every 10th line start with their number and an arrow (10→); the markers are not part of the file. For large files, grep for what you need first, then read with offset/limit (1-based).","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"write","description":"Create or overwrite a file with the given content. Creates parent directories.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},
    \\{"type":"function","function":{"name":"edit","description":"Replace exact text in a file. One change: old_string + new_string. Several changes in one file: edits, a list of {old_string, new_string}, each matched against the file as it was before this call; all apply or none do. Each old_string must occur exactly once; include enough context. Read the file first; leave out read's N→ line markers.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","description":"with old_string: replace every occurrence (renames)"},"edits":{"type":"array","items":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["old_string","new_string"]}}},"required":["path"]}}},
    \\{"type":"function","function":{"name":"bash","description":"Run a bash command in the working directory. Returns stdout+stderr and exit code. Default timeout 120 s.","parameters":{"type":"object","properties":{"command":{"type":"string"},"timeout":{"type":"integer","description":"seconds"},"background":{"type":"boolean","description":"start it and return at once (servers, watchers, long test runs); output goes to a log file"},"network":{"type":"boolean","description":"needs the internet (install, download, clone); the user approves each such command"}},"required":["command"]}}},
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
    var full: [1024]u8 = undefined;
    const s0 = std.fmt.bufPrint(&full, f, a) catch full[0..];
    var sb: [1024]u8 = undefined;
    const short = ui.shorten(s0, &sb); // paths under the project read as relative
    const s = r.summary[0..@min(short.len, r.summary.len)];
    @memcpy(s, short[0..s.len]);
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
        const p = std.json.parseFromSliceLeaky(struct { path: Str, offset: ?Int(usize) = null, limit: ?Int(usize) = null }, a, args, opts) catch return badArgs(out, name, args, &r);
        const path = p.path.v;
        sum(&r, name, "{s}", .{path});
        r.ok = read(path, if (p.offset) |o| o.v else 1, if (p.limit) |l| l.v else 2000, out);
        if (r.ok) files_read.note(path);
    } else if (eq(u8, name, "write")) {
        const p = std.json.parseFromSliceLeaky(struct { path: Str, content: Str }, a, args, opts) catch return badArgs(out, name, args, &r);
        const path = p.path.v;
        const content = p.content.v;
        sum(&r, name, "{s} ({d} lines)", .{ path, std.mem.count(u8, content, "\n") + @intFromBool(content.len > 0 and content[content.len - 1] != '\n') });
        if (outside(path, out)) return r;
        if (try guarded(name, path, out)) return r;
        if (!try gate(name, true, out)) return r;
        save(path);
        r.ok = write(path, &.{content}, out);
        if (r.ok) files_changed.note(path);
        if (r.ok) out.print("wrote {d} bytes to {s}", .{ content.len, path });
    } else if (eq(u8, name, "edit")) {
        const E = struct { old_string: ?Str = null, new_string: ?Str = null, old: ?Str = null, new: ?Str = null };
        const p = std.json.parseFromSliceLeaky(struct { path: Str, old_string: ?Str = null, new_string: ?Str = null, old: ?Str = null, new: ?Str = null, replace_all: bool = false, edits: ?[]const E = null }, a, args, opts) catch return badArgs(out, name, args, &r);
        const path = p.path.v;
        if (outside(path, out) or try guarded(name, path, out)) {
            sum(&r, name, "{s}", .{path});
            return r;
        }
        var pairs: [max_edits]Pair = undefined;
        var n: usize = 0;
        if (opt(p.old_string) orelse opt(p.old)) |old| {
            pairs[0] = .{ .old = old, .new = opt(p.new_string) orelse opt(p.new) orelse return badArgs(out, name, args, &r) };
            n = 1;
        }
        for (p.edits orelse &.{}) |e| {
            if (n == max_edits) {
                out.print("too many edits in one call (max {d}); split them", .{max_edits});
                sum(&r, name, "{s}", .{path});
                return r;
            }
            pairs[n] = .{ .old = opt(e.old_string) orelse opt(e.old) orelse return badArgs(out, name, args, &r), .new = opt(e.new_string) orelse opt(e.new) orelse return badArgs(out, name, args, &r) };
            n += 1;
        }
        if (n == 0) return badArgs(out, name, args, &r);
        if (p.replace_all and n == 1) {
            sum(&r, name, "{s} (all)", .{path});
            const preview = mode != .auto;
            if (preview) ui.diff(pairs[0].old, pairs[0].new);
            if (!try gate(name, true, out)) return r;
            save(path);
            r.ok = replaceAll(path, pairs[0].old, pairs[0].new, out);
            if (r.ok) files_changed.note(path);
            if (r.ok and !preview) ui.diff(pairs[0].old, pairs[0].new);
            return r;
        }
        if (n == 1) sum(&r, name, "{s}", .{path}) else sum(&r, name, "{s} ({d} changes)", .{ path, n });
        const preview = mode != .auto; // show the change before asking
        if (preview) for (pairs[0..n]) |pp| ui.diff(pp.old, pp.new);
        if (!try gate(name, true, out)) return r;
        save(path);
        r.ok = editFile(path, pairs[0..n], out);
        if (r.ok) files_changed.note(path);
        if (r.ok and !preview) for (pairs[0..n]) |pp| ui.diff(pp.old, pp.new);
    } else if (eq(u8, name, "todo")) {
        const p = std.json.parseFromSliceLeaky(struct { items: []const struct { text: Str, status: Str = .{ .v = "pending" } } }, a, args, opts) catch return badArgs(out, name, args, &r);
        var done: usize = 0;
        for (p.items) |it| done += @intFromBool(eq(u8, it.status.v, "done") or eq(u8, it.status.v, "skip"));
        sum(&r, name, "{d}/{d} done", .{ done, p.items.len });
        r.ok = todo(p.items, out);
    } else if (eq(u8, name, "bash")) {
        const p = std.json.parseFromSliceLeaky(struct { command: Str, timeout: ?Int(u32) = null, background: bool = false, network: bool = false }, a, args, opts) catch return badArgs(out, name, args, &r);
        if (p.background) sum(&r, name, "&{s}", .{p.command.v}) else sum(&r, name, "{s}", .{p.command.v});
        const online = p.network and sandbox.on and !sandbox.net;
        if (online) {
            if (p.background) {
                out.add("not run: a command with network cannot run in the background; run it in the foreground");
                return r;
            }
            if (!try networkApproved(out)) return r;
        } else {
            ask_command = p.command.v;
            defer ask_command = "";
            if (!try gate(name, false, out)) return r;
        }
        if (!sandboxReady(out)) return r;
        const cmd = a.dupeZ(u8, p.command.v) catch return badArgs(out, name, args, &r);
        if (p.background) {
            r.ok = startJob(cmd, out);
            return r;
        }
        const av = [_:null]?[*:0]const u8{ "/bin/bash", "-c", cmd };
        net_once = online;
        defer net_once = false;
        r.ok = try spawn(&av, @as(u64, if (p.timeout) |x| x.v else 120) * 1000, out, .bash, true);
        if (online) out.add("\n[ran with network, approved by the user for this command only]");
    } else if (eq(u8, name, "grep") and have_rg) {
        const p = std.json.parseFromSliceLeaky(struct { pattern: Str, path: ?Str = null, glob: ?Str = null, context: ?Int(u8) = null, ignore_case: bool = false, limit: ?Int(usize) = null }, a, args, opts) catch return badArgs(out, name, args, &r);
        const pattern = p.pattern.v;
        var cb0: [4096]u8 = undefined;
        const path = rel(opt(p.path) orelse ".", &cb0);
        sum(&r, name, "{s} {s}", .{ pattern, path });
        var argv: [24:null]?[*:0]const u8 = .{ rg_path, "-n", "--no-heading", "--color", "never", "--smart-case", "--max-columns", "300", "--max-columns-preview" } ++ .{null} ** 15;
        var n: usize = 9;
        if (p.glob) |g| {
            argv[n] = "-g";
            argv[n + 1] = a.dupeZ(u8, g.v) catch return badArgs(out, name, args, &r);
            n += 2;
        }
        if (p.context) |cx| if (cx.v > 0) {
            const c = cx.v;
            var cb: [8]u8 = undefined;
            argv[n] = "-C";
            argv[n + 1] = a.dupeZ(u8, std.fmt.bufPrint(&cb, "{d}", .{@min(c, 20)}) catch "2") catch return badArgs(out, name, args, &r);
            n += 2;
        };
        if (p.ignore_case) {
            argv[n] = "-i";
            n += 1;
        }
        argv[n] = "-e";
        argv[n + 1] = a.dupeZ(u8, pattern) catch return badArgs(out, name, args, &r);
        argv[n + 2] = "--";
        argv[n + 3] = a.dupeZ(u8, path) catch return badArgs(out, name, args, &r);
        if (!sandboxReady(out)) return r;
        r.ok = try spawn(&argv, 30_000, out, .grep, true);
        capLines(out, @min(if (p.limit) |l| l.v else 200, 1000), "lines");
    } else if (eq(u8, name, "find") and have_fd) {
        const q = std.json.parseFromSliceLeaky(struct { pattern: ?Str = null, path: ?Str = null }, a, args, opts) catch return badArgs(out, name, args, &r);
        var cb0: [4096]u8 = undefined;
        const p = .{ .pattern = opt(q.pattern), .path = if (opt(q.path)) |x| rel(x, &cb0) else null };
        sum(&r, name, "{s} {s}", .{ p.pattern orelse "*", p.path orelse "." });
        var argv: [9:null]?[*:0]const u8 = .{ fd_path, "--color", "never", "--max-results", "501" } ++ .{null} ** 4;
        var pat = p.pattern orelse "";
        var i: usize = 5;
        if (pat.len > 0 and pat[0] == '*') { // a glob (*.py, *.py$): never a valid regex, so read it as the glob it is
            pat = std.mem.trimEnd(u8, pat, "$");
            argv[i] = "--glob";
            i += 1;
        }
        argv[i] = a.dupeZ(u8, pat) catch return badArgs(out, name, args, &r);
        argv[i + 1] = a.dupeZ(u8, p.path orelse ".") catch return badArgs(out, name, args, &r);
        if (!sandboxReady(out)) return r;
        r.ok = try spawn(&argv, 30_000, out, .find, true);
        capLines(out, 500, "entries");
    } else {
        out.print("unknown tool: {s}", .{name});
        sum(&r, name, "?", .{});
    }
    return r;
}

/// Say what is wrong so the model can fix the call in one step: not JSON (cut off?), or which fields are missing.
const sandbox = @import("sandbox.zig");

fn workdir() []const u8 {
    const S = struct {
        var b: [4096]u8 = undefined;
    };
    const rc = linux.getcwd(&S.b, S.b.len);
    return if (linux.errno(rc) == .SUCCESS) std.mem.sliceTo(&S.b, 0) else ".";
}

/// write/edit outside what the sandbox allows: refuse, and say what is writable.
fn outside(path: []const u8, out: *Buf) bool {
    var nb: [4096]u8 = undefined;
    const abs = sandbox.normalize(path, workdir(), &nb);
    if (sandbox.writable(abs)) return false;
    out.print("not written: {s} is outside the sandbox (writable: the project {s}, /tmp, build caches; the user can add AWL_SANDBOX_WRITE=dir)", .{ abs, sandbox.root });
    return true;
}

/// Set while the user is asked about a guarded path or the network: y/n only, never "all".
pub var asking_once = false;

/// write/edit to the project's .git, AGENTS.md or .agents: the user says yes every time, in
/// every mode; with nobody to ask, no. true: refused, and `out` says why.
fn guarded(name: []const u8, path: []const u8, out: *Buf) error{Cancel}!bool {
    var nb: [4096]u8 = undefined;
    const abs = sandbox.normalize(path, workdir(), &nb);
    if (!sandbox.guardedPath(abs)) return false;
    const f = ask orelse {
        out.print("not written: {s} is guarded (git config and hooks run outside the sandbox; AGENTS.md and skills instruct later sessions). Only the user can approve this, in a terminal session.", .{abs});
        return true;
    };
    ui.note("{s} changes {s}, which runs outside the sandbox or instructs later sessions", .{ name, abs });
    ask_reason = "change a guarded file (git config, hooks, AGENTS.md or skills)";
    asking_once = true;
    defer asking_once = false;
    switch (f()) {
        .yes, .always => return false,
        .no => {
            out.print("The user declined this {s} call to {s}.", .{ name, abs });
            return true;
        },
        .cancel => {
            out.add("[interrupted by user]");
            return error.Cancel;
        },
    }
}

/// Set for one approved command: it runs in its own sandbox with the host network.
var net_once = false;

/// A command that wants the network: the user approves this one call, in every mode
/// (the tool line above shows the exact command). With nobody to ask, no.
fn networkApproved(out: *Buf) error{Cancel}!bool {
    const f = ask orelse {
        out.add("not run: the network is off in the sandbox and only the user can approve a command that needs it, in a terminal session. Do without it, or ask the user to run the command with !");
        return false;
    };
    ui.note("this command wants the network (this call only)", .{});
    ask_reason = "use the network";
    asking_once = true;
    defer asking_once = false;
    return switch (f()) {
        .yes, .always => true,
        .no => blk: {
            out.add("The user declined network access for this command. Do without it, or ask the user.");
            break :blk false;
        },
        .cancel => blk: {
            out.add("[interrupted by user]");
            break :blk error.Cancel;
        },
    };
}

/// The model's commands need the session sandbox (or AWL_SANDBOX=off). false: `out` says why.
fn sandboxReady(out: *Buf) bool {
    if (sandbox.missing) {
        out.add("not run: awl runs the model's commands in a bubblewrap sandbox and /usr/bin/bwrap is missing. Tell the user: install bubblewrap, or restart awl with AWL_SANDBOX=off to run commands unsandboxed.");
        return false;
    }
    if (!sandbox.on) return true;
    if (sandbox.ready()) |why| {
        out.print("not run: {s}. Tell the user; AWL_SANDBOX=off runs commands unsandboxed.", .{why});
        return false;
    }
    return true;
}

fn badArgs(out: *Buf, name: []const u8, args: []const u8, r: *Result) Result {
    r.ok = false;
    const eql = std.mem.eql;
    if (!(std.json.validate(std.heap.page_allocator, args) catch false)) {
        out.print("invalid arguments for {s}: not valid JSON (was the call cut off?)", .{name});
        return r.*;
    }
    const need: []const []const u8 = if (eql(u8, name, "write")) &.{ "path", "content" } else if (eql(u8, name, "edit") or eql(u8, name, "read")) &.{"path"} else if (eql(u8, name, "bash")) &.{"command"} else if (eql(u8, name, "todo")) &.{"items"} else if (eql(u8, name, "grep")) &.{"pattern"} else &.{};
    var mb: [96]u8 = undefined;
    var m = std.ArrayListUnmanaged(u8).initBuffer(&mb);
    for (need) |k| {
        var kb: [32]u8 = undefined;
        const q = std.fmt.bufPrint(&kb, "\"{s}\"", .{k}) catch continue;
        if (std.mem.indexOf(u8, args, q) != null) continue;
        if (m.items.len > 0) m.appendSliceBounded(", ") catch {};
        m.appendSliceBounded(k) catch {};
    }
    const has = struct {
        fn f(a: []const u8, k: []const u8) bool {
            return std.mem.indexOf(u8, a, k) != null;
        }
    }.f;
    if (eql(u8, name, "edit") and !has(args, "\"edits\"") and (!has(args, "\"old_string\"") or !has(args, "\"new_string\""))) {
        if (m.items.len > 0) m.appendSliceBounded(", ") catch {};
        m.appendSliceBounded("old_string + new_string (or edits)") catch {};
    }
    if (m.items.len > 0) out.print("invalid arguments for {s}: missing {s}", .{ name, m.items }) else out.print("invalid arguments for {s}: a field has the wrong type; check the tool's parameters", .{name});
    return r.*;
}

/// A path inside the working directory, made relative, so grep and find print short paths: long absolute paths
/// are what models mis-copy. Anything else is returned unchanged.
fn rel(path: []const u8, cb: *[4096]u8) []const u8 {
    if (linux.errno(linux.getcwd(cb, cb.len)) != .SUCCESS) return path;
    const c = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(cb)), 0);
    if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), c)) return ".";
    if (c.len > 1 and path.len > c.len + 1 and std.mem.startsWith(u8, path, c) and path[c.len] == '/') return path[c.len + 1 ..];
    return path;
}

fn errMsg(out: *Buf, what: []const u8, path: []const u8, e: anyerror) bool {
    out.print("{s} {s}: {s}", .{ what, path, switch (e) {
        error.NotFound => "no such file or directory",
        error.Access => "permission denied",
        error.IsDir => "is a directory",
        else => @tagName(sys.last_errno),
    } });
    if (e == error.NotFound) _ = pathHint(out, path);
    return false;
}

/// A path that does not exist: say what was probably meant, so a mis-copied path costs one turn instead of a
/// guessing loop. Models copying long paths drop folders (…/bench/run-1/… for …/bench/2026-10-19/runs/run-1/…)
/// or repeat them (…/app/app/app.html for …/app/app.html). From the deepest folder that exists: the missing
/// part with leading folders left out, then the missing part under a folder up to 3 levels down, else the
/// names there that start like the missing one. False when there is nothing to say.
pub fn pathHint(out: *Buf, path: []const u8) bool {
    const p = std.mem.trimEnd(u8, path, "/");
    if (p.len == 0 or p.len > 1024 or sys.exists(p)) return false;
    var dir: []const u8 = ".";
    var ms: usize = 0; // p[ms..] is the missing part
    var end = p.len;
    while (std.mem.lastIndexOfScalar(u8, p[0..end], '/')) |i| {
        const d = if (i == 0) "/" else p[0..i];
        if (sys.exists(d)) {
            dir = d;
            ms = i + 1;
            break;
        }
        end = i;
    }
    const miss = p[ms..];
    var pb: [2048]u8 = undefined;
    // extra folders: leave out leading parts of the missing path
    var k = std.mem.indexOfScalar(u8, miss, '/');
    while (k) |i| : (k = std.mem.indexOfScalarPos(u8, miss, i + 1, '/')) {
        const c = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, miss[i + 1 ..] }) catch return false;
        if (sys.exists(c)) {
            out.print(" Did you mean {s}?", .{c});
            return true;
        }
    }
    // dropped folders: the missing part under a folder below `dir`
    var budget: usize = 400; // folders opened at most
    const n = std.fmt.bufPrint(&pb, "{s}", .{dir}) catch return false;
    if (std.mem.indexOfScalar(u8, miss, '/') != null) if (findUnder(&pb, n.len, miss, 3, &budget)) |c| {
        out.print(" Did you mean {s}?", .{c});
        return true;
    };
    // else: names in `dir` that start like the missing one
    const want = miss[0 .. std.mem.indexOfScalar(u8, miss, '/') orelse miss.len];
    const dfd = sys.open(dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return false;
    defer sys.close(dfd);
    var best: [5][]const u8 = undefined;
    var score: [5]usize = .{0} ** 5;
    var keep: [5][256]u8 = undefined;
    var b: [8192]u8 align(8) = undefined;
    while (true) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
        if (got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off + @offsetOf(linux.dirent64, "name")])), 0);
            off += e.reclen;
            var s: usize = 0;
            while (s < @min(name.len, want.len) and std.ascii.toLower(name[s]) == std.ascii.toLower(want[s])) s += 1;
            if (s < 3 or name.len > 255) continue;
            var w: usize = 0; // replace the weakest kept name
            for (score, 0..) |v, j| {
                if (v < score[w]) w = j;
            }
            if (s <= score[w]) continue;
            @memcpy(keep[w][0..name.len], name);
            best[w] = keep[w][0..name.len];
            score[w] = s;
        }
    }
    var shown = false;
    for (score, 0..) |v, j| {
        if (v == 0) continue;
        if (shown) out.print(", {s}", .{best[j]}) else out.print(" Close names in {s}/: {s}", .{ dir, best[j] });
        shown = true;
    }
    return shown;
}

/// Depth-first search below `pb[0..n]` (a folder) for a subfolder `f` with `f/miss` existing; returns that path
/// in `pb`. Skips hidden folders and node_modules; stops after `budget` folders.
fn findUnder(pb: *[2048]u8, n: usize, miss: []const u8, depth: u8, budget: *usize) ?[]const u8 {
    if (depth == 0 or budget.* == 0) return null;
    budget.* -= 1;
    const dfd = sys.open(pb[0..n], .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return null;
    defer sys.close(dfd);
    var b: [4096]u8 align(8) = undefined;
    while (true) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch return null;
        if (got == 0) return null;
        var off: usize = 0;
        while (off < got) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off + @offsetOf(linux.dirent64, "name")])), 0);
            off += e.reclen;
            if (e.type != linux.DT.DIR or name[0] == '.' or std.mem.eql(u8, name, "node_modules")) continue;
            const m = (std.fmt.bufPrint(pb[n..], "/{s}", .{name}) catch continue).len + n;
            const c = std.fmt.bufPrint(pb[m..], "/{s}", .{miss}) catch continue;
            if (sys.exists(pb[0 .. m + c.len])) return pb[0 .. m + c.len];
            if (findUnder(pb, m, miss, depth - 1, budget)) |r| return r;
        }
    }
}

/// Absolute paths a command reported missing ("…: No such file or directory"), at most 2, each with a hint.
fn missingHints(out: *Buf, base: usize) void {
    var seen: [2][]const u8 = undefined;
    var ns: usize = 0;
    var hb = Buf.init(8192);
    defer hb.free();
    var it = std.mem.splitScalar(u8, out.items()[base..], '\n');
    while (it.next()) |line| {
        if (ns == seen.len) break;
        const at = std.mem.indexOf(u8, line, ": No such file or directory") orelse continue;
        const sp = std.mem.lastIndexOfAny(u8, line[0..at], " '\"`") orelse continue;
        const pth = std.mem.trim(u8, line[sp + 1 .. at], "'\"`");
        if (pth.len < 2 or pth[0] != '/') continue;
        var dup = false;
        for (seen[0..ns]) |s| dup = dup or std.mem.eql(u8, s, pth);
        if (dup) continue;
        seen[ns] = pth;
        ns += 1;
        const mark = hb.len;
        hb.print("\n[{s} does not exist.", .{pth});
        if (pathHint(&hb, pth)) hb.add("]") else hb.len = mark;
    }
    out.add(hb.items());
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
    var nb: [4096]u8 = undefined;
    if (sandbox.hidden(sandbox.normalize(path, workdir(), &nb))) {
        out.print("not read: {s} is hidden from the model (secrets, other processes, the user's sockets)", .{path});
        return false;
    }
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
        if (shown == 0 or ln % 10 == 0) out.print("{d}→", .{ln});
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
    var fmode: linux.mode_t = 0o644;
    var pb: [4096]u8 = undefined;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, sys.z(&pb, path), 0, .{ .MODE = true }, &st)) == .SUCCESS) fmode = st.mode & 0o7777;
    const fd = sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, fmode) catch |e| return errMsg(out, "write", path, e);
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
            if (std.mem.eql(u8, it.status.v, k)) break true;
        } else false;
        if (!known) {
            out.print("unknown status \"{s}\" for \"{s}\"; use pending, doing, done or skip", .{ it.status.v, it.text.v });
            return false;
        }
    }
    out.add(todo_marker);
    var done: usize = 0;
    for (items) |it| {
        const eq = std.mem.eql;
        const mark: []const u8 = if (eq(u8, it.status.v, "done")) "[x]" else if (eq(u8, it.status.v, "doing")) "[>]" else if (eq(u8, it.status.v, "skip")) "[-]" else "[ ]";
        done += @intFromBool(eq(u8, it.status.v, "done") or eq(u8, it.status.v, "skip"));
        out.print("\n{s} {s}", .{ mark, it.text.v });
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
    // Models writing raw tool arguments (XML formats) sometimes escape quotes as if in JSON: t[\"due\"].
    // When the text as sent is not there but the unescaped text occurs exactly once, use that (new text too).
    var unesc = false;
    for (fixed[0..pairs.len]) |*f| {
        if (std.mem.indexOf(u8, m.bytes, f.old) != null) continue;
        if (std.mem.indexOf(u8, f.old, "\\\"") == null and std.mem.indexOf(u8, f.old, "\\'") == null) continue;
        const o0 = conv.len;
        dropQuoteEscapes(f.old, &conv);
        const n0 = conv.len;
        dropQuoteEscapes(f.new, &conv);
        const o = conv.items()[o0..n0];
        if (std.mem.count(u8, m.bytes, o) == 1) {
            f.* = .{ .old = o, .new = conv.items()[n0..] };
            unesc = true;
        }
    }
    const ok = editIn(path, m.bytes, fixed[0..pairs.len], out);
    if (ok and unesc) out.add(" (matched after removing backslashes before quotes; new_string unescaped the same way)");
    return ok;
}

fn dropQuoteEscapes(s: []const u8, out: *Buf) void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '"' or s[i + 1] == '\'')) continue;
        out.byte(s[i]);
    }
}

/// Replace every occurrence of `old` (exact text; CRLF files are matched like edit does).
fn replaceAll(path: []const u8, old: []const u8, new: []const u8, out: *Buf) bool {
    if (old.len == 0) {
        out.add("old_string is empty");
        return false;
    }
    const m = mapFile(path) catch |e| return errMsg(out, "edit", path, e);
    defer m.deinit();
    var ob = Buf.init(old.len * 2 + 16);
    var nb_ = Buf.init(new.len * 2 + 16);
    defer ob.free();
    defer nb_.free();
    var o = old;
    var nw = new;
    if (std.mem.indexOf(u8, m.bytes, old) == null and std.mem.indexOf(u8, m.bytes, "\r\n") != null) {
        toCrlf(old, &ob);
        toCrlf(new, &nb_);
        o = ob.items();
        nw = nb_.items();
    }
    const count = std.mem.count(u8, m.bytes, o);
    if (count == 0) {
        out.print("old_string not found in {s}.", .{path});
        if (!missHint(m.bytes, o, out)) out.add(" Read the file and copy the text exactly, including whitespace.");
        return false;
    }
    var body = Buf.init(m.bytes.len + count * (nw.len + 1) + 16);
    defer body.free();
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, m.bytes, pos, o)) |i| {
        body.add(m.bytes[pos..i]);
        body.add(nw);
        pos = i + o.len;
    }
    body.add(m.bytes[pos..]);
    if (!write(path, &.{body.items()}, out)) return false;
    out.print("replaced {d} occurrences in {s}", .{ count, path });
    return true;
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
            if (!missHint(bytes, p.old, out)) out.add(" Read the file and copy the text exactly, including whitespace.");
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

/// Where a missing old_string stops matching the file: the longest leading part of it that occurs in the file
/// (binary search; whether a prefix occurs is monotone in its length), then the file line and the old_string line
/// at the first difference. A stray leading quote or backtick (models copy them from template strings) is retried
/// without. False when not even 8 bytes match, so the caller gives the generic hint.
fn missHint(bytes: []const u8, old: []const u8, out: *Buf) bool {
    var o = std.mem.trim(u8, old, " \t\r\n");
    var dropped: ?u8 = null;
    var k = matchedPrefix(bytes, o);
    if (k < 8 and o.len > 1 and std.mem.indexOfScalar(u8, "`'\"", o[0]) != null) {
        const k2 = matchedPrefix(bytes, o[1..]);
        if (k2 >= 8) {
            dropped = o[0];
            o = o[1..];
            k = k2;
        }
    }
    if (k < 8) return false;
    const pos = std.mem.indexOf(u8, bytes, o[0..k]).?;
    const fd = pos + k; // first byte that differs, in the file
    const fs = if (std.mem.lastIndexOfScalar(u8, bytes[0..fd], '\n')) |n| n + 1 else 0;
    const fl = std.mem.trimEnd(u8, bytes[fs .. std.mem.indexOfScalarPos(u8, bytes, fd, '\n') orelse bytes.len], "\r");
    const line = std.mem.count(u8, bytes[0..fs], "\n") + 1;
    if (k == o.len) {
        if (dropped) |c|
            out.print(" Without its leading {c} it occurs at line {d}: `{s}`", .{ c, line, around(fl, fd - fs) })
        else
            out.print(" It occurs at line {d} with different whitespace around it: `{s}`", .{ line, around(fl, fd - fs) });
        return true;
    }
    if (dropped) |c| out.print(" Without its leading {c} it", .{c}) else out.add(" It");
    const os = if (std.mem.lastIndexOfScalar(u8, o[0..k], '\n')) |n| n + 1 else 0;
    const ol = std.mem.trimEnd(u8, o[os .. std.mem.indexOfScalarPos(u8, o, k, '\n') orelse o.len], "\r");
    const ws = std.mem.eql(u8, std.mem.trim(u8, fl, " \t"), std.mem.trim(u8, ol, " \t"));
    out.print(" matches the file up to line {d}, where the file has ", .{line});
    quoted(out, around(fl, fd - fs));
    out.add(" and old_string has ");
    quoted(out, around(ol, k - os));
    out.print("{s}.", .{if (ws) " (whitespace differs)" else ""});
    return true;
}

fn matchedPrefix(bytes: []const u8, o: []const u8) usize {
    var lo: usize = 0; // o[0..lo] occurs
    var hi: usize = o.len + 1; // o[0..hi] does not (or past the end)
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.indexOf(u8, bytes, o[0..mid]) != null) lo = mid else hi = mid;
    }
    return lo;
}

/// At most 160 bytes of a line, starting up to 60 before column `col` when the line is longer, so the
/// difference stays in view; cut on UTF-8 boundaries.
fn around(s: []const u8, col: usize) []const u8 {
    var a: usize = if (s.len > 160 and col > 60) @min(col - 60, s.len - 160) else 0;
    while (a > 0 and (s[a] & 0xC0) == 0x80) a -= 1;
    var c = @min(s.len, a + 160);
    while (c < s.len and c > a and (s[c] & 0xC0) == 0x80) c -= 1;
    return s[a..c];
}

fn quoted(out: *Buf, s: []const u8) void {
    if (std.mem.trim(u8, s, " \t").len == 0) out.add("an empty line") else out.print("`{s}`", .{s});
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
/// Paths the model read or changed this session (for compaction summaries). Up to 64 each.
pub const PathSet = struct {
    buf: [64][200]u8 = undefined,
    len: [64]u8 = undefined,
    n: usize = 0,
    pub fn note(self: *PathSet, p: []const u8) void {
        if (p.len == 0 or p.len > 200) return;
        for (0..self.n) |i| if (std.mem.eql(u8, self.buf[i][0..self.len[i]], p)) return;
        if (self.n == self.buf.len) return;
        @memcpy(self.buf[self.n][0..p.len], p);
        self.len[self.n] = @intCast(p.len);
        self.n += 1;
    }
    pub fn list(self: *const PathSet, out: *Buf) void {
        for (0..self.n) |i| {
            out.add(self.buf[i][0..self.len[i]]);
            out.byte('\n');
        }
    }
};
pub var files_read = PathSet{};
pub var files_changed = PathSet{};

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
    var pp: [2]i32 = .{ -1, -1 };
    if (sandbox.on) _ = linux.pipe2(&pp, .{ .CLOEXEC = true });
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
        const av = [_:null]?[*:0]const u8{ "/bin/bash", "-c", cmd };
        const e = sandbox.envp(sys.envp, &env);
        if (sandbox.on) sandbox.execIn(&av, e, @ptrCast(workdir().ptr), pp[1]);
        _ = linux.execve(av[0].?, &av, e);
        linux.exit_group(127);
    }
    sys.close(lfd);
    // Inside the sandbox the job has its own pid; the model needs that one to stop it.
    var shown: linux.pid_t = pid;
    if (sandbox.on) {
        sys.close(pp[1]);
        var nb: [16]u8 = undefined;
        const n = sys.read(pp[0], &nb) catch 0;
        sys.close(pp[0]);
        shown = std.fmt.parseInt(linux.pid_t, nb[0..n], 10) catch pid;
    }
    const c = std.mem.span(cmd);
    slot.* = .{ .pid = pid, .id = job_seq, .log = slot.log, .log_n = path.len, .cmd_n = @min(c.len, 60) };
    @memcpy(slot.cmd[0..slot.cmd_n], c[0..slot.cmd_n]);
    out.print("started background job {d} (pid {d}); output goes to {s}. Read it with read or tail; stop it with: kill -- -{d}", .{ job_seq, shown, path, shown });
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
/// `model`: the model's command (sandboxed, allowlisted environment); else the user's own.
fn spawn(argv: [*:null]const ?[*:0]const u8, timeout_ms: u64, out: *Buf, kind: Kind, model: bool) error{Cancel}!bool {
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
        _ = linux.setsid(); // own session and process group: no terminal, one kill stops it all
        const devnull = linux.open("/dev/null", .{}, 0);
        _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.dup2(p[1], 1);
        _ = linux.dup2(p[1], 2);
        sys.unblockAll();
        var env: [1024]?[*:0]const u8 = undefined; // this desktop already has ~220 vars
        if (model) {
            const e = sandbox.envp(sys.envp, &env);
            if (sandbox.on and net_once) sandbox.execOnline(argv, e, @ptrCast(workdir().ptr));
            if (sandbox.on) sandbox.execIn(argv, e, @ptrCast(workdir().ptr), -1);
            _ = linux.execve(argv[0].?, argv, e);
        } else _ = linux.execve(argv[0].?, argv, sys.childEnvp(sys.envp, &env));
        linux.exit_group(127);
    }
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
        if (sys.tick != null) wait_ms = @min(wait_ms, sys.tick_ms);
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
            sys.maybeTick();
            continue;
        }
        sys.maybeTick();
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
    if (code != 0 and dropped == 0) missingHints(out, base);
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

test "missing paths get a did-you-mean: dropped folders, repeated folders, close names, bash output" {
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var cb: [512]u8 = undefined;
    var out = Buf.init(1 << 20);
    const mk = try std.fmt.bufPrint(&cb, "{{\"command\":\"cd {s} && rm -rf ph && mkdir -p ph/bench/2026-10-19/runs/run-1/bb ph/app ph/bench/bonsai-a ph/bench/bonsai-b && touch ph/bench/2026-10-19/runs/run-1/bb/x.js ph/app/app.html\"}}", .{d});
    _ = try run("bash", mk, &out);
    var pb: [256]u8 = undefined;
    var eb: [512]u8 = undefined;
    // dropped folders (the awl slip)
    out.reset();
    _ = pathHint(&out, try std.fmt.bufPrint(&pb, "{s}/ph/bench/run-1/bb/x.js", .{d}));
    try t.expectEqualStrings(try std.fmt.bufPrint(&eb, " Did you mean {s}/ph/bench/2026-10-19/runs/run-1/bb/x.js?", .{d}), out.items());
    // repeated folders (the omp loop)
    out.reset();
    _ = pathHint(&out, try std.fmt.bufPrint(&pb, "{s}/ph/app/app/app/app.html", .{d}));
    try t.expectEqualStrings(try std.fmt.bufPrint(&eb, " Did you mean {s}/ph/app/app.html?", .{d}), out.items());
    // nothing found below: names that start like the missing one
    out.reset();
    _ = pathHint(&out, try std.fmt.bufPrint(&pb, "{s}/ph/bench/bonsai-c/y.js", .{d}));
    try t.expect(std.mem.indexOf(u8, out.items(), "Close names in ") != null and std.mem.indexOf(u8, out.items(), "bonsai-a") != null and std.mem.indexOf(u8, out.items(), "bonsai-b") != null);
    // read's error, and a command's "No such file or directory" line
    out.reset();
    _ = try run("read", try std.fmt.bufPrint(&cb, "{{\"path\":\"{s}/ph/app/app/app.html\"}}", .{d}), &out);
    try t.expect(std.mem.endsWith(u8, out.items(), try std.fmt.bufPrint(&eb, "no such file or directory Did you mean {s}/ph/app/app.html?", .{d})));
    out.reset();
    _ = try run("bash", try std.fmt.bufPrint(&cb, "{{\"command\":\"cat {s}/ph/bench/run-1/bb/x.js\"}}", .{d}), &out);
    try t.expect(std.mem.endsWith(u8, out.items(), try std.fmt.bufPrint(&eb, "[{s}/ph/bench/run-1/bb/x.js does not exist. Did you mean {s}/ph/bench/2026-10-19/runs/run-1/bb/x.js?]", .{ d, d })));
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
    try t.expectEqualStrings("1→def f():\n    return 2\n", out.items());
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
    try t.expectEqualStrings("2→two\ntwo\n[lines 2-3 of 4; use offset=4 to continue]", out.items());
    out.reset();
    try t.expect(!edit(f, "two", "2", &out));
    try t.expect(std.mem.indexOf(u8, out.items(), "matches 2 places") != null);
    out.reset();
    try t.expect(!edit(f, "four", "4", &out));
    out.reset();
    try t.expect(edit(f, "two\nthree", "3", &out));
    out.reset();
    try t.expect(read(f, 1, 2000, &out));
    try t.expectEqualStrings("1→one\ntwo\n3\n", out.items());
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

test "edit: quotes escaped as in JSON still match once; real escapes are left alone" {
    ui.quiet = true;
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/esc.py", .{d});
    var out = Buf.init(1 << 20);
    var fb: [256]u8 = undefined;
    try t.expect(write(f, &.{"x = t[\"due\"]\ny = 'a\\'b'\n"}, &out));
    out.reset();
    var ab: [512]u8 = undefined;
    // the model sent t[\"due\"] (backslashes in the decoded string)
    const args = try std.fmt.bufPrint(&ab, "{{\"path\":\"{s}\",\"old_string\":\"x = t[\\\\\\\"due\\\\\\\"]\",\"new_string\":\"x = t[\\\\\\\"when\\\\\\\"]\"}}", .{f});
    const r = try run("edit", args, &out);
    try t.expect(r.ok);
    try t.expectEqualStrings("x = t[\"when\"]\ny = 'a\\'b'\n", try sys.readFile(f, &fb));
    try t.expect(std.mem.endsWith(u8, out.items(), "new_string unescaped the same way)"));
    // a backslash that is really in the file is matched as sent, untouched
    out.reset();
    const args2 = try std.fmt.bufPrint(&ab, "{{\"path\":\"{s}\",\"old_string\":\"'a\\\\'b'\",\"new_string\":\"'a\\\\'c'\"}}", .{f});
    try t.expect((try run("edit", args2, &out)).ok);
    try t.expectEqualStrings("x = t[\"when\"]\ny = 'a\\'c'\n", try sys.readFile(f, &fb));
}

test "bad tool arguments say what is wrong" {
    ui.quiet = true;
    var out = Buf.init(1 << 16);
    _ = try run("edit", "{\"old_string\":\"a\",\"new_string\":\"b\"}", &out);
    try t.expectEqualStrings("invalid arguments for edit: missing path", out.items());
    out.reset();
    _ = try run("edit", "{\"path\":\"x\"}", &out);
    try t.expectEqualStrings("invalid arguments for edit: missing old_string + new_string (or edits)", out.items());
    out.reset();
    _ = try run("write", "{\"path\":\"x\",\"content\":\"abc", &out);
    try t.expectEqualStrings("invalid arguments for write: not valid JSON (was the call cut off?)", out.items());
    out.reset();
    _ = try run("write", "{}", &out);
    try t.expectEqualStrings("invalid arguments for write: missing path, content", out.items());
}

test "find reads a leading-* pattern as a glob" {
    detect();
    if (!have_fd) return error.SkipZigTest;
    ui.quiet = true;
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    var out = Buf.init(1 << 16);
    try t.expect(write(try std.fmt.bufPrint(&pb, "{s}/a.py", .{d}), &.{"x"}, &out));
    try t.expect(write(try std.fmt.bufPrint(&pb, "{s}/b.txt", .{d}), &.{"x"}, &out));
    var ab: [256]u8 = undefined;
    for ([_][]const u8{ "*.py", "*.py$" }) |g| {
        out.reset();
        const r = try run("find", try std.fmt.bufPrint(&ab, "{{\"pattern\":\"{s}\",\"path\":\"{s}\"}}", .{ g, d }), &out);
        try t.expect(r.ok);
        try t.expect(std.mem.indexOf(u8, out.items(), "a.py") != null and std.mem.indexOf(u8, out.items(), "b.txt") == null);
    }
}

test "read marks the first line and every 10th line" {
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/n.txt", .{d});
    var out = Buf.init(1 << 20);
    try t.expect(write(f, &.{"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"}, &out));
    out.reset();
    try t.expect(read(f, 8, 4, &out));
    try t.expectEqualStrings("8→h\ni\n10→j\nk\n[lines 8-11 of 12; use offset=12 to continue]", out.items());
}

test "edit replace_all" {
    ui.quiet = true;
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/ra.txt", .{d});
    var out = Buf.init(1 << 20);
    var fb: [128]u8 = undefined;
    try t.expect(write(f, &.{"foo(1); foo(2);\nbar(foo);\n"}, &out));
    var ab: [256]u8 = undefined;
    out.reset();
    const r = try run("edit", try std.fmt.bufPrint(&ab, "{{\"path\":\"{s}\",\"old_string\":\"foo\",\"new_string\":\"baz\",\"replace_all\":true}}", .{f}), &out);
    try t.expect(r.ok);
    try t.expect(std.mem.startsWith(u8, out.items(), "replaced 3 occurrences in "));
    try t.expectEqualStrings("baz(1); baz(2);\nbar(baz);\n", try sys.readFile(f, &fb));
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
    try t.expectEqualStrings("old_string not found in src/a.zig. It occurs at line 2 with different whitespace around it: `    const x = foo(1);`", out.items());
}

test "edit: not-found hint names the first line that differs" {
    var out = Buf.init(1 << 20);
    const file = "}\nfn main() {\n    const x = foo(1);\n    const y = bar(2);\n}\n";
    // the first lines match exactly; a later line's text differs (blaming whitespace here sent models into cat -A loops)
    try t.expect(!editIn("src/a.zig", file, &.{.{ .old = "fn main() {\n    const x = foo(1);\n    const y = baz(2);", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in src/a.zig. It matches the file up to line 4, where the file has `    const y = bar(2);` and old_string has `    const y = baz(2);`.", out.items());
    out.reset();
    // a later line differs only in indentation
    try t.expect(!editIn("src/a.zig", file, &.{.{ .old = "fn main() {\n    const x = foo(1);\n\tconst y = bar(2);", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in src/a.zig. It matches the file up to line 4, where the file has `    const y = bar(2);` and old_string has `\tconst y = bar(2);` (whitespace differs).", out.items());
    out.reset();
    // a first line that occurs many times (`}`) still finds the right place
    try t.expect(!editIn("src/a.zig", file, &.{.{ .old = "}\nfn main() {\n    const x = foo(9);", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in src/a.zig. It matches the file up to line 3, where the file has `    const x = foo(1);` and old_string has `    const x = foo(9);`.", out.items());
}

test "edit: not-found hint on a near miss" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("src/a.zig", "pub fn readFile(path: []const u8) void\n", &.{.{ .old = "pub fn readFile(path: []const u8, n: usize) void", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in src/a.zig. It matches the file up to line 1, where the file has `pub fn readFile(path: []const u8) void` and old_string has `pub fn readFile(path: []const u8, n: usize) void`.", out.items());
}

test "edit: not-found hint retries a fragment without its stray leading backtick" {
    var out = Buf.init(1 << 20);
    const file = "const a = 1;\n  return `${n} x @ ${fmt(p, c)} = ${fmt(t)}`;\n";
    try t.expect(!editIn("a.js", file, &.{.{ .old = "`@ ${fmt(p, c)} = ${fmt(t, c)}`", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in a.js. Without its leading ` it matches the file up to line 2, where the file has `  return `${n} x @ ${fmt(p, c)} = ${fmt(t)}`;` and old_string has `@ ${fmt(p, c)} = ${fmt(t, c)}``.", out.items());
}

test "edit: not-found hint when a stray leading backtick is the only difference" {
    var out = Buf.init(1 << 20);
    try t.expect(!editIn("a.js", "  return `${n} @ ${fmt(p)}`;\n", &.{.{ .old = "`@ ${fmt(p)}`;", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in a.js. Without its leading ` it occurs at line 1: `  return `${n} @ ${fmt(p)}`;`", out.items());
}

test "edit: not-found hint keeps a late difference in a long line in view, and names empty lines" {
    var out = Buf.init(1 << 20);
    const long = "y" ** 300;
    try t.expect(!editIn("a", "a();\n" ++ long ++ "Z\n", &.{.{ .old = "a();\n" ++ long ++ "Q", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in a. It matches the file up to line 2, where the file has `" ++ "y" ** 159 ++ "Z` and old_string has `" ++ "y" ** 159 ++ "Q`.", out.items());
    out.reset();
    try t.expect(!editIn("a", "fn a() {\n  b();\n}\n", &.{.{ .old = "fn a() {\n\n  b();", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in a. It matches the file up to line 2, where the file has `  b();` and old_string has an empty line.", out.items());
}

test "edit: long file line in the hint is cut on a utf-8 boundary" {
    var out = Buf.init(1 << 20);
    const line = "x" ** 159 ++ "é and more";
    try t.expect(!editIn("a", line ++ "\n", &.{.{ .old = "x" ** 20 ++ "y", .new = "" }}, &out));
    try t.expectEqualStrings("old_string not found in a. It matches the file up to line 1, where the file has `" ++ "x" ** 159 ++ "` and old_string has `" ++ "x" ** 20 ++ "y`.", out.items());
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
    try t.expect(try spawn(&a, 10_000, &out, .bash, false));
    try t.expect(sys.nowNs() - t0 < 2 * std.time.ns_per_s);
    try t.expectEqualStrings("started\n", out.items());
}

test "spawn: output, exit code, truncation, timeout kills grandchild" {
    var out = Buf.init(1 << 20);
    const a1 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "echo hi; exit 3" };
    try t.expect(!try spawn(&a1, 5000, &out, .bash, false));
    try t.expectEqualStrings("hi\n\n[exit 3]", out.items());
    out.reset();
    const a2 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "head -c 200000 /dev/zero | tr '\\0' x" };
    try t.expect(try spawn(&a2, 5000, &out, .bash, false));
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
    try t.expect(try spawn(&a_small, 5000, &out, .bash, false));
    try t.expectEqualStrings("small\n", out.items()); // short output: no log file mentioned
    out.reset();
    const t0 = sys.nowNs();
    const a3 = [_:null]?[*:0]const u8{ "/bin/bash", "-c", "(sleep 30; echo leaked) & sleep 30" };
    try t.expect(!try spawn(&a3, 300, &out, .bash, false));
    try t.expect(sys.nowNs() - t0 < 2 * std.time.ns_per_s);
    try t.expect(std.mem.indexOf(u8, out.items(), "timed out") != null);
}

test "number arguments: plain, quoted and 1.0" {
    ui.quiet = true;
    var db: [64]u8 = undefined;
    const d = tmpdir(&db);
    var pb: [128]u8 = undefined;
    const f = try std.fmt.bufPrint(&pb, "{s}/num.txt", .{d});
    var out = Buf.init(1 << 20);
    try t.expect(write(f, &.{"a\nb\nc\nd\n"}, &out));
    out.reset();
    var ab: [256]u8 = undefined;
    const r = try run("read", try std.fmt.bufPrint(&ab, "{{\"path\":\"{s}\",\"offset\":2,\"limit\":\"2\"}}", .{f}), &out);
    try t.expect(r.ok);
    try t.expectEqualStrings("2→b\nc\n[lines 2-3 of 4; use offset=4 to continue]", out.items());
    out.reset();
    const b = try run("bash", "{\"command\":\"sleep 3\",\"timeout\":1.0}", &out);
    try t.expect(!b.ok);
    try t.expect(std.mem.endsWith(u8, out.items(), "[timed out after 1 s; process group killed]"));
    out.reset();
    _ = try run("read", try std.fmt.bufPrint(&ab, "{{\"path\":\"{s}\",\"offset\":1.5}}", .{f}), &out);
    try t.expect(std.mem.startsWith(u8, out.items(), "invalid arguments for read"));
}
