//! Agents: every running awl (a TUI, or a background agent) keeps a small status file next
//! to its session, `<session>.live`, and holds a lock on it while it runs. A reader that can
//! take the lock knows the owner is gone, so "running" never outlives a crash and no pid is
//! trusted. Background agents are detached `awl --bg -p PROMPT` processes: they read
//! steering messages from `<session>.inbox` and approval answers from `<session>.answer`.
//! Other sidecars: `<session>.title` (a name the user gave it), `<session>.log` (a background
//! agent's own output).
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");
const Buf = @import("buf.zig").Buf;
const bufm = @import("buf.zig");

const LOCK_SH = 1;
const LOCK_EX = 2;
const LOCK_NB = 4;

pub const Kind = enum { tui, bg };
pub const State = enum { idle, running, waiting, done, failed, stopped };

/// `<session path minus .jsonl><ext>` in `buf`.
pub fn sidecar(path: []const u8, ext: []const u8, buf: []u8) []const u8 {
    const base = if (std.mem.endsWith(u8, path, ".jsonl")) path[0 .. path.len - 6] else path;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, ext }) catch "";
}

// ---- the owner: this process's own status ----

pub var enabled = false; // set by main for the TUI and for --bg (not for plain -p)
pub var kind: Kind = .tui;
pub var state: State = .idle;
var live_fd: sys.fd_t = -1;
var live_path_b: [600]u8 = undefined;
var live_path: []const u8 = ""; // the .live file
var cur_step: usize = 0;
var doing_b: [160]u8 = undefined;
var now_doing: []const u8 = "";
var ask_b: [400]u8 = undefined;
var now_ask: []const u8 = "";
var since: i64 = 0; // wall clock when the state last changed
var run_t0: i64 = 0;

/// The session file was opened (created or resumed): take its status file.
pub fn begin() void {
    if (!enabled or session.path.len == 0) return;
    end();
    live_path = sidecar(session.path, ".live", &live_path_b);
    const f = sys.open(live_path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600) catch return;
    if (linux.errno(linux.flock(f, LOCK_EX | LOCK_NB)) != .SUCCESS) { // another awl has it
        sys.close(f);
        return;
    }
    live_fd = f;
    cur_step = 0;
    now_doing = "";
    now_ask = "";
    if (kind == .bg) { // a background agent's output goes to <session>.log
        var lb: [600]u8 = undefined;
        if (sys.open(sidecar(session.path, ".log", &lb), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600)) |l| {
            _ = linux.dup2(l, 1);
            _ = linux.dup2(l, 2);
            sys.close(l);
        } else |_| {}
    }
    set(if (kind == .bg) .running else .idle);
}

/// The session file is being closed. A TUI's status file goes away; a background agent's
/// stays with its final state, for the dashboard.
pub fn end() void {
    if (live_fd < 0) return;
    if (kind == .tui) {
        var zb: [600]u8 = undefined;
        _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, live_path), 0);
    }
    sys.close(live_fd); // releases the lock
    live_fd = -1;
}

pub fn set(s: State) void {
    if (s == .running and state != .running and state != .waiting) {
        run_t0 = sys.wallSec();
        cur_step = 0;
    }
    if (s != .waiting) now_ask = "";
    if (s != .running and s != .waiting) now_doing = "";
    state = s;
    since = sys.wallSec();
    write();
}

/// A new model request in the turn.
pub fn progress(n: usize) void {
    cur_step = n;
    now_doing = "thinking";
    writeSoon();
}

/// A tool call started (from ui.tool).
pub fn activity(name: []const u8, summary: []const u8) void {
    if (live_fd < 0) return;
    now_doing = std.fmt.bufPrint(&doing_b, "{s} {s}", .{ name, summary[0..@min(summary.len, doing_b.len - name.len - 1)] }) catch name;
    while (now_doing.len > 0 and (now_doing[now_doing.len - 1] & 0xC0) == 0x80) now_doing = now_doing[0 .. now_doing.len - 1];
    writeSoon();
}

fn writeSoon() void {
    write(); // one small pwrite per step or tool call
}

fn write() void {
    if (live_fd < 0) return;
    var b = Buf.init(4096);
    defer b.free();
    b.print("{{\"pid\":{d},\"kind\":\"{s}\",\"state\":\"{s}\",\"step\":{d},\"since\":{d},\"secs\":{d},\"changed\":{d},\"doing\":", .{
        linux.getpid(), @tagName(kind),                                                          @tagName(state), cur_step, since,
        if (run_t0 > 0) @max(sys.wallSec() - run_t0, 0) else 0, tools.files_changed.n,
    });
    bufm.str(&b, now_doing);
    b.add(",\"ask\":");
    bufm.str(&b, now_ask);
    b.add("}\n");
    _ = linux.ftruncate(live_fd, 0);
    _ = linux.pwrite(live_fd, b.items().ptr, b.len, 0);
}

// ---- background agents ----

/// Start a detached background agent in this folder on `prompt`; it continues the session
/// at `resume_path` when given. It uses the current model and mode.
pub fn spawn(prompt: []const u8, resume_path: ?[]const u8, model: []const u8, mode: []const u8) bool {
    var pb = Buf.init(prompt.len + 1);
    defer pb.free();
    pb.add(prompt);
    pb.byte(0);
    var rb: [600]u8 = undefined;
    var mb: [300]u8 = undefined;
    var ob: [32]u8 = undefined;
    const model_e = std.fmt.bufPrintZ(&mb, "AWL_MODEL={s}", .{model}) catch return false;
    const mode_e = std.fmt.bufPrintZ(&ob, "AWL_MODE={s}", .{mode}) catch return false;
    var env: [1024]?[*:0]const u8 = undefined;
    var n: usize = 0;
    for (sys.envp) |e| {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "AWL_MODEL=") or std.mem.startsWith(u8, s, "AWL_MODE=") or std.mem.startsWith(u8, s, "AWL_FULL=")) continue;
        if (n + 3 >= env.len) break;
        env[n] = e;
        n += 1;
    }
    env[n] = model_e.ptr;
    env[n + 1] = mode_e.ptr;
    env[n + 2] = null;
    var argv: [7:null]?[*:0]const u8 = .{ "awl", "--bg", "-p", @ptrCast(pb.items().ptr), null, null, null };
    if (resume_path) |r| {
        argv[4] = "-r";
        argv[5] = (std.fmt.bufPrintZ(&rb, "{s}", .{r}) catch return false).ptr;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return false;
    if (pid != 0) { // the middle child exits at once, so the agent is nobody's zombie
        var st: u32 = 0;
        _ = linux.wait4(@intCast(pid), &st, 0, null);
        return true;
    }
    _ = linux.setsid(); // no terminal: closing this one leaves the agent running
    if (linux.fork() != 0) linux.exit(0);
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    _ = linux.dup2(@intCast(devnull), 0);
    _ = linux.dup2(@intCast(devnull), 1);
    _ = linux.dup2(@intCast(devnull), 2);
    sys.unblockAll();
    _ = linux.execve("/proc/self/exe", &argv, @ptrCast(&env));
    linux.exit(127);
}

/// --bg: an approval question. Waits for `<session>.answer` (written by the dashboard), or a stop.
pub fn bgAsk() tools.Answer {
    now_ask = std.fmt.bufPrint(&ask_b, "{s}{s}{s}", .{ tools.ask_reason, if (tools.ask_reason.len > 0) ": " else "", now_doing }) catch now_doing;
    set(.waiting);
    notify("needs your approval");
    var ab: [600]u8 = undefined;
    const ap = sidecar(session.path, ".answer", &ab);
    while (true) {
        var p = [1]linux.pollfd{.{ .fd = sys.sigfd, .events = linux.POLL.IN, .revents = 0 }};
        _ = linux.poll(&p, 1, 300);
        if (p[0].revents != 0) {
            sys.drainSignals();
            set(.running);
            return .cancel;
        }
        var fb: [16]u8 = undefined;
        const a = sys.readFile(ap, &fb) catch continue;
        var zb: [600]u8 = undefined;
        _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, ap), 0);
        const c = if (a.len > 0) a[0] else 'n';
        set(.running);
        return switch (c) {
            'y' => .yes,
            'a' => if (tools.asking_once) .yes else .always,
            else => .no,
        };
    }
}

var inbox_mem = Buf.init(4 << 20);

/// --bg: messages sent from the dashboard, taken before the next step.
pub fn bgSteer() ?[]const u8 {
    var ib: [600]u8 = undefined;
    var tb: [600]u8 = undefined;
    const ip = sidecar(session.path, ".inbox", &ib);
    const tp = sidecar(session.path, ".inbox.taking", &tb);
    var z1: [600]u8 = undefined;
    var z2: [600]u8 = undefined;
    if (linux.errno(linux.renameat(linux.AT.FDCWD, sys.z(&z1, ip), linux.AT.FDCWD, sys.z(&z2, tp))) != .SUCCESS) return null;
    inbox_mem.reset();
    const f = sys.open(tp, .{ .CLOEXEC = true }, 0) catch return null;
    while (true) {
        const dst = inbox_mem.extend(1 << 16);
        const got = sys.read(f, dst) catch 0;
        inbox_mem.truncate(inbox_mem.len - (dst.len - got));
        if (got == 0) break;
    }
    sys.close(f);
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&z1, tp), 0);
    const t = std.mem.trim(u8, inbox_mem.items(), " \n");
    return if (t.len > 0) t else null;
}

/// A desktop notification from a background agent, naming its task.
pub fn notify(what: []const u8) void {
    var tb: [200]u8 = undefined;
    var title_b: [120]u8 = undefined;
    const title = titleOf(session.path, &title_b, &tb);
    var mb: [400]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&mb, "“{s}” {s}", .{ title, what }) catch return;
    const pid = linux.fork();
    if (pid != 0) {
        var st: u32 = 0;
        if (linux.errno(pid) == .SUCCESS) _ = linux.wait4(@intCast(pid), &st, 0, null);
        return;
    }
    if (linux.fork() != 0) linux.exit(0);
    sys.unblockAll();
    var env: [1024]?[*:0]const u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/notify-send", "-a", "awl", "awl agent", msg };
    _ = linux.execve("/usr/bin/notify-send", &argv, sys.childEnvp(sys.envp, &env));
    linux.exit(0);
}

// ---- readers: the dashboard and the status line ----

pub const Info = struct {
    alive: bool = false,
    kind: Kind = .tui,
    state: State = .idle,
    pid: i32 = 0,
    step: u32 = 0,
    since: i64 = 0,
    secs: u32 = 0,
    changed: u32 = 0,
    doing_b: [160]u8 = undefined,
    doing_n: usize = 0,
    ask_b: [400]u8 = undefined,
    ask_n: usize = 0,
    pub fn doing(i: *const Info) []const u8 {
        return i.doing_b[0..i.doing_n];
    }
    pub fn question(i: *const Info) []const u8 {
        return i.ask_b[0..i.ask_n];
    }
    /// Running or waiting in a live background agent.
    pub fn active(i: *const Info) bool {
        return i.alive and i.kind == .bg and (i.state == .running or i.state == .waiting);
    }
};

/// The status file of the session at `jsonl`, if it has one.
pub fn readLive(jsonl: []const u8, out: *Info) bool {
    var pb: [600]u8 = undefined;
    const p = sidecar(jsonl, ".live", &pb);
    const f = sys.open(p, .{ .CLOEXEC = true }, 0) catch return false;
    defer sys.close(f);
    var b: [2048]u8 = undefined;
    const n = sys.read(f, &b) catch return false;
    const j = b[0..n];
    if (n < 10 or j[0] != '{') return false;
    out.* = .{};
    out.alive = linux.errno(linux.flock(f, LOCK_SH | LOCK_NB)) != .SUCCESS; // held: its owner runs
    out.kind = std.meta.stringToEnum(Kind, field(j, "kind", &out.doing_b)) orelse .tui;
    out.state = std.meta.stringToEnum(State, field(j, "state", &out.doing_b)) orelse .idle;
    out.pid = @intCast(num(j, "pid"));
    out.step = @intCast(@max(num(j, "step"), 0));
    out.since = num(j, "since");
    out.secs = @intCast(@max(num(j, "secs"), 0));
    out.changed = @intCast(@max(num(j, "changed"), 0));
    out.ask_n = field(j, "ask", &out.ask_b).len;
    out.doing_n = field(j, "doing", &out.doing_b).len;
    return true;
}

/// Integer field `key` of a flat JSON object awl wrote (0 when missing).
pub fn num(j: []const u8, key: []const u8) i64 {
    const v = value(j, key) orelse return 0;
    var e: usize = 0;
    if (e < v.len and v[e] == '-') e += 1;
    while (e < v.len and std.ascii.isDigit(v[e])) e += 1;
    return std.fmt.parseInt(i64, v[0..e], 10) catch 0;
}

/// What follows `"key":` (and any spaces) in `j`.
fn value(j: []const u8, key: []const u8) ?[]const u8 {
    var kb: [40]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "\"{s}\":", .{key}) catch return null;
    const i = std.mem.indexOf(u8, j, k) orelse return null;
    return std.mem.trimStart(u8, j[i + k.len ..], " \t\n\r");
}

/// String field `key` of a JSON object, decoded into `out` (cut to fit).
pub fn field(j: []const u8, key: []const u8, out: []u8) []const u8 {
    const v = value(j, key) orelse return out[0..0];
    if (v.len == 0 or v[0] != '"') return out[0..0];
    return unquote(v[1..], out);
}

/// The body of a JSON string (starting after its opening quote), decoded into `out`.
pub fn unquote(s: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) : (i += 1) {
        const c = s[i];
        if (c == '"') break;
        if (c != '\\' or i + 1 >= s.len) {
            out[n] = c;
            n += 1;
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => out[n] = '\n',
            't' => out[n] = '\t',
            'r' => out[n] = '\r',
            'u' => {
                const cp = if (i + 4 < s.len) std.fmt.parseInt(u21, s[i + 1 .. i + 5], 16) catch '?' else '?';
                i += 4;
                var eb: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(if (cp >= 0xD800 and cp <= 0xDFFF) 0xFFFD else cp, &eb) catch 1;
                if (n + len > out.len) break;
                @memcpy(out[n .. n + len], eb[0..len]);
                n += len;
                continue;
            },
            else => |x| out[n] = x,
        }
        n += 1;
    }
    while (n > 0 and n == out.len and (out[n - 1] & 0xC0) == 0x80) n -= 1; // whole UTF-8 characters
    if (n > 0 and n == out.len and (out[n - 1] & 0xC0) == 0xC0) n -= 1;
    return out[0..n];
}

test "unquote and fields" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\"b\nc é", unquote("a\\\"b\\nc \\u00e9\" tail", &b));
    const j = "{\"pid\":42,\"state\":\"waiting\",\"ask\":\"network: curl \\\"x\\\"\"}";
    try std.testing.expectEqual(@as(i64, 42), num(j, "pid"));
    try std.testing.expectEqualStrings("waiting", field(j, "state", &b));
    try std.testing.expectEqualStrings("network: curl \"x\"", field(j, "ask", &b));
    try std.testing.expectEqual(@as(i64, 0), num(j, "nope"));
    try std.testing.expectEqualStrings("sleep 3", field("{\"command\": \"sleep 3\"}", "command", &b)); // models put spaces in

}

/// The name a session goes by: its title file, else its first prompt (one line).
pub fn titleOf(jsonl: []const u8, out: []u8, scratch: []u8) []const u8 {
    var pb: [600]u8 = undefined;
    if (sys.readFile(sidecar(jsonl, ".title", &pb), out)) |t| {
        const s = std.mem.trim(u8, t, " \r\n\t");
        if (s.len > 0) return s;
    } else |_| {}
    const text = sys.readFile(jsonl, scratch) catch return out[0..0];
    return firstPrompt(text, out);
}

/// The first user prompt in session text, as one line (a leading [note] skipped).
pub fn firstPrompt(text: []const u8, out: []u8) []const u8 {
    const pre = "{\"role\":\"user\",\"content\":\"";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, pre)) continue;
        var body = line[pre.len..];
        if (std.mem.startsWith(u8, body, "[")) { // a note from /undo, /mode or !cmd comes first
            if (std.mem.indexOf(u8, body, "]\\n\\n")) |k| body = body[k + 5 ..];
        }
        const s = unquote(body, out);
        for (@constCast(s)) |*c| if (c.* == '\n' or c.* == '\t' or c.* == '\r') {
            c.* = ' ';
        };
        return std.mem.trim(u8, s, " ");
    }
    return out[0..0];
}

/// One saved session, for the dashboard.
pub const Row = struct {
    name_b: [72]u8 = undefined,
    name_n: usize = 0,
    title_b: [160]u8 = undefined,
    title_n: usize = 0,
    cwd_b: [300]u8 = undefined,
    cwd_n: usize = 0,
    model_b: [80]u8 = undefined,
    model_n: usize = 0,
    mtime: i64 = 0,
    size: u64 = 0,
    has_live: bool = false,
    live: Info = .{},
    pub fn name(r: *const Row) []const u8 {
        return r.name_b[0..r.name_n];
    }
    pub fn title(r: *const Row) []const u8 {
        return r.title_b[0..r.title_n];
    }
    pub fn cwd(r: *const Row) []const u8 {
        return r.cwd_b[0..r.cwd_n];
    }
    pub fn model(r: *const Row) []const u8 {
        return r.model_b[0..r.model_n];
    }
    pub fn path(r: *const Row, buf: []u8) []const u8 {
        var db: [400]u8 = undefined;
        const d = session.dirPath(&db) orelse return "";
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ d, r.name() }) catch "";
    }
    /// Re-read only the status file (cheap; the dashboard does it several times a second).
    pub fn refreshLive(r: *Row) void {
        var pb: [600]u8 = undefined;
        r.has_live = readLive(r.path(&pb), &r.live);
    }
};

/// Sessions newest first (at most out.len), only those started in `cwd` unless it is null.
/// Sessions with no prompt yet are skipped unless something is running in them.
pub fn scan(cwd: ?[]const u8, out: []Row) []Row {
    var db: [400]u8 = undefined;
    const d = session.dirPath(&db) orelse return out[0..0];
    const dfd = sys.open(d, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return out[0..0];
    defer sys.close(dfd);
    var names = Buf.init(1 << 20); // names, each ending in 0
    defer names.free();
    var count: usize = 0;
    var b: [8192]u8 align(8) = undefined;
    while (true) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
        if (got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            off += e.reclen;
            const nm = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off - e.reclen + @offsetOf(linux.dirent64, "name")])), 0);
            if (!std.mem.endsWith(u8, nm, ".jsonl") or nm.len > 72) continue;
            names.add(nm);
            names.byte(0);
            count += 1;
        }
    }
    // newest first: names start with the UTC time
    var list = Buf.init(@max(count, 1) * @sizeOf([]const u8));
    defer list.free();
    const slots = @as([*][]const u8, @ptrCast(@alignCast(list.extend(count * @sizeOf([]const u8)).ptr)))[0..count];
    var it = std.mem.splitScalar(u8, names.items(), 0);
    var k: usize = 0;
    while (it.next()) |nm| if (nm.len > 0 and k < count) {
        slots[k] = nm;
        k += 1;
    };
    const C = struct {
        fn gt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .gt;
        }
    };
    std.sort.pdq([]const u8, slots[0..k], {}, C.gt);
    var n: usize = 0;
    var head = Buf.init(16384);
    defer head.free();
    for (slots[0..k]) |nm| {
        if (n == out.len) break;
        var pb: [600]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ d, nm }) catch continue;
        var r = &out[n];
        r.* = .{};
        @memcpy(r.name_b[0..nm.len], nm);
        r.name_n = nm.len;
        // the meta line and the first prompt are near the top
        head.reset();
        const f = sys.open(p, .{ .CLOEXEC = true }, 0) catch continue;
        const dst = head.extend(16384);
        const got = sys.read(f, dst) catch 0;
        head.truncate(got);
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(f, "", linux.AT.EMPTY_PATH, .{ .SIZE = true, .MTIME = true }, &st)) == .SUCCESS) {
            r.mtime = st.mtime.sec;
            r.size = st.size;
        }
        sys.close(f);
        const text = head.items();
        const meta = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        r.cwd_n = field(meta, "cwd", &r.cwd_b).len;
        if (cwd) |c| if (!std.mem.eql(u8, r.cwd(), c)) continue;
        r.model_n = field(meta, "model", &r.model_b).len;
        r.has_live = readLive(p, &r.live);
        var tb: [600]u8 = undefined;
        var title_b: [160]u8 = undefined;
        const t = if (sys.readFile(sidecar(p, ".title", &tb), &title_b)) |x| std.mem.trim(u8, x, " \r\n\t") else |_| "";
        const shown = if (t.len > 0) t else firstPrompt(text, &r.title_b);
        if (t.len > 0) @memcpy(r.title_b[0..shown.len], shown);
        r.title_n = shown.len;
        if (r.title_n == 0 and !(r.has_live and r.live.alive)) continue;
        n += 1;
    }
    return out[0..n];
}

/// Running and waiting background agents, in every folder (for the status line).
pub const Summary = struct { running: usize = 0, waiting: usize = 0 };

/// Background agents whose state changed since the last poll: finished, or waiting for an answer.
pub const Event = struct { name_b: [72]u8 = undefined, name_n: usize = 0, state: State = .idle };

var seen_names: [256][72]u8 = undefined;
var seen_len: [256]usize = undefined;
var seen_state: [256]State = undefined;
var seen_n: usize = 0;
var baselined = false; // the first poll only records what is there

/// Look at every status file: count what runs, and report background agents whose state
/// changed since the last poll (or that appeared already finished). Cheap: one directory
/// read and a few small files.
pub fn poll(events: []Event) struct { sum: Summary, events: []Event } {
    var s = Summary{};
    var ne: usize = 0;
    defer baselined = true;
    var db: [400]u8 = undefined;
    const d = session.dirPath(&db) orelse return .{ .sum = s, .events = events[0..0] };
    const dfd = sys.open(d, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch return .{ .sum = s, .events = events[0..0] };
    defer sys.close(dfd);
    var b: [8192]u8 align(8) = undefined;
    while (true) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
        if (got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            off += e.reclen;
            const nm = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off - e.reclen + @offsetOf(linux.dirent64, "name")])), 0);
            if (!std.mem.endsWith(u8, nm, ".live") or nm.len > 72) continue;
            var pb: [600]u8 = undefined;
            const jsonl = std.fmt.bufPrint(&pb, "{s}/{s}.jsonl", .{ d, nm[0 .. nm.len - 5] }) catch continue;
            var info: Info = .{};
            if (!readLive(jsonl, &info) or info.kind != .bg) continue;
            const st = shownState(&info);
            if (st == .running) s.running += 1;
            if (st == .waiting) s.waiting += 1;
            const base = nm[0 .. nm.len - 5];
            var slot: ?usize = null;
            for (0..seen_n) |i| if (std.mem.eql(u8, seen_names[i][0..seen_len[i]], base)) {
                slot = i;
            };
            const changed = if (slot) |i| seen_state[i] != st else baselined;
            if (changed and st != .running and st != .idle and ne < events.len) {
                events[ne] = .{ .state = st, .name_n = base.len };
                @memcpy(events[ne].name_b[0..base.len], base);
                ne += 1;
            }
            const i = slot orelse blk: {
                if (seen_n == seen_names.len) seen_n = 0; // full: start over (only notes are at stake)
                seen_n += 1;
                @memcpy(seen_names[seen_n - 1][0..base.len], base);
                seen_len[seen_n - 1] = base.len;
                break :blk seen_n - 1;
            };
            seen_state[i] = st;
        }
    }
    return .{ .sum = s, .events = events[0..ne] };
}

/// The state to show: a status file says running, but nobody holds its lock → the agent died.
pub fn shownState(i: *const Info) State {
    if (!i.alive and (i.state == .running or i.state == .waiting or i.state == .idle) and i.kind == .bg) return .failed;
    return i.state;
}

/// Write one sidecar file whole (title, answer); empty `text` removes it.
pub fn putSidecar(jsonl: []const u8, ext: []const u8, text: []const u8) bool {
    var pb: [600]u8 = undefined;
    const p = sidecar(jsonl, ext, &pb);
    var zb: [600]u8 = undefined;
    if (text.len == 0) return linux.errno(linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, p), 0)) == .SUCCESS;
    const f = sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch return false;
    defer sys.close(f);
    sys.writeAll(f, text) catch return false;
    return true;
}

/// Queue a message for a background agent (it reads its inbox before each step).
pub fn sendInbox(jsonl: []const u8, text: []const u8) bool {
    var pb: [600]u8 = undefined;
    const p = sidecar(jsonl, ".inbox", &pb);
    const f = sys.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch return false;
    defer sys.close(f);
    sys.writeAll(f, text) catch return false;
    sys.writeAll(f, "\n\n") catch return false;
    return true;
}

/// Remove a session and its sidecars.
pub fn remove(jsonl: []const u8) void {
    var zb: [600]u8 = undefined;
    for ([_][]const u8{ ".title", ".live", ".log", ".inbox", ".answer" }) |ext| {
        var pb: [600]u8 = undefined;
        _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, sidecar(jsonl, ext, &pb)), 0);
    }
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, jsonl), 0);
}

/// Is another awl (a background agent, or a TUI in another terminal) using this session now?
pub fn busyElsewhere(jsonl: []const u8) ?Info {
    if (std.mem.eql(u8, jsonl, session.path)) return null;
    var info: Info = .{};
    if (readLive(jsonl, &info) and info.alive) return info;
    return null;
}
