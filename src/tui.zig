//! Interactive prompt: a small raw-mode line editor, inline (no alternate screen).
//! Raw mode is on only while typing. While the agent runs the terminal is
//! cooked with echo off, so Ctrl-C arrives as SIGINT and cancels the turn.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const ui = @import("ui.zig");
const agent = @import("agent.zig");
const session = @import("session.zig");
const http = @import("http.zig");
const Buf = @import("buf.zig").Buf;
const tools = @import("tools.zig");
const llm = @import("llm.zig");
const screen = @import("screen.zig");

var orig: linux.termios = undefined;
var have_orig = false;

/// Raw input the whole session, so keys typed while the agent works reach the
/// editor unmangled. `signals` turns ISIG on while the agent runs: Ctrl-C then
/// arrives as SIGINT on the signalfd and cancels the turn.
fn setMode(signals: bool) void {
    if (!have_orig) return;
    var t = orig;
    t.lflag.ECHO = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = signals;
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false;
    t.iflag.ICRNL = false;
    t.cc[@intFromEnum(linux.V.MIN)] = 1;
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
    _ = linux.ioctl(sys.stdin, linux.T.CSETS, @intFromPtr(&t));
}

/// Put the terminal back the way we found it (also called on panic).
pub fn restore() void {
    if (!have_orig) return;
    leaveFull();
    _ = linux.ioctl(sys.stdin, linux.T.CSETSW, @intFromPtr(&orig));
    out("\x1b[?2004l\x1b[?1004l\x1b[0m");
}

fn out(s: []const u8) void {
    sys.writeAll(sys.stdout, s) catch {};
}

pub var start_full = false; // awl --full / AWL_FULL=1

/// Full-screen mode on: the alternate screen, mouse wheel reports (SGR encoding).
fn enterFull() void {
    if (screen.on) return;
    out("\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[H\x1b[2J");
    screen.on = true;
    ui.redraw = &fullDraw;
}

/// Back to the normal screen, and print there what was shown, so it stays in the scrollback.
fn leaveFull() void {
    if (!screen.on) return;
    screen.on = false;
    ui.redraw = null;
    out("\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l");
    const t = screen.all();
    out(t);
    if (t.len > 0 and t[t.len - 1] != '\n') out("\r\n");
    screen.reset();
}

/// Full-screen mode: compose the rows under the conversation (live area while a turn
/// runs, the input, the status line) and draw.
fn fullDraw() void {
    const w: usize = sys.termCols();
    const h: usize = sys.termRows();
    var b = Buf.init(1 << 20);
    defer b.free();
    var rows: [128][]const u8 = undefined;
    var n: usize = 0;
    var ends: [128]usize = undefined;
    const S = struct {
        fn cut(bb: *Buf, e: *[128]usize, nn: *usize) void {
            if (nn.* < e.len) {
                e[nn.*] = bb.len;
                nn.* += 1;
            }
        }
    };
    if (ui.busy) {
        var lb = Buf.init(16 << 10);
        defer lb.free();
        ui.liveRows(&lb, w -| 1);
        var it = std.mem.splitScalar(u8, lb.items(), '\n');
        while (it.next()) |r| {
            b.add(r);
            S.cut(&b, &ends, &n);
        }
    }
    var cursor: ?[2]usize = null;
    const ed = editor;
    const typing = ed != null and !ui.busy and ed.?.foot;
    if (typing) {
        const e = ed.?;
        const max_rows = @max(h / 3, 3);
        var lb = Buf.init(e.len * 2 + 4096);
        defer lb.free();
        const all_ = e.layout(w, 0, 0, null);
        var lo: usize = 0;
        var hi: usize = all_.rows;
        if (all_.rows > max_rows) {
            hi = @min(all_.rows, @max(all_.cur_row + 1, max_rows));
            lo = hi - max_rows;
        }
        const r = e.layout(w, lo, hi, &lb);
        var it = std.mem.splitSequence(u8, lb.items(), "\r\n");
        const first = n;
        while (it.next()) |row| {
            b.add(row);
            S.cut(&b, &ends, &n);
        }
        cursor = .{ first + r.cur_row - lo, r.cur_col };
    } else {
        b.add(ui.accent());
        b.add(prompt);
        b.add(ui.plain());
        if (ui.busy) { // type-ahead: the end of the draft, on one row
            const d = ui.draft;
            var st = d.len -| (w -| 4);
            while (st < d.len and (d[st] & 0xC0) == 0x80) st += 1;
            for (d[st..]) |c| b.byte(if (c == '\n') ' ' else c);
            cursor = .{ n, 2 + (std.unicode.utf8CountCodepoints(d[st..]) catch d.len - st) };
        }
        S.cut(&b, &ends, &n);
    }
    if (statusOn()) {
        footer(&b, w -| 1);
        S.cut(&b, &ends, &n);
    }
    var start: usize = 0;
    for (ends[0..n], 0..) |e, k| {
        rows[k] = b.items()[start..e];
        start = e;
    }
    screen.draw(rows[0..n], cursor);
}

/// PgUp/PgDn and the mouse wheel scroll the full-screen view. `s` is a CSI sequence's
/// body ("5~", "<64;10;3M"); true when it was one of these.
fn scrollKey(s: []const u8) bool {
    if (!screen.on) return false;
    const page: isize = @intCast(@max(@as(usize, sys.termRows()) / 2, 1));
    if (std.mem.eql(u8, s, "5~")) {
        screen.scrollBy(page);
    } else if (std.mem.eql(u8, s, "6~")) {
        screen.scrollBy(-page);
    } else if (s.len > 0 and s[0] == '<') { // mouse: wheel up 64, down 65; clicks ignored
        if (std.mem.startsWith(u8, s, "<64;")) screen.scrollBy(3);
        if (std.mem.startsWith(u8, s, "<65;")) screen.scrollBy(-3);
    } else return false;
    ui.drawNow();
    return true;
}

pub fn repl() u8 {
    if (!sys.isatty(sys.stdin) or !sys.isatty(sys.stdout)) return plain();
    have_orig = linux.errno(linux.ioctl(sys.stdin, linux.T.CGETS, @intFromPtr(&orig))) == .SUCCESS;
    defer restore();
    out("\x1b[?2004h\x1b[?1004h"); // bracketed paste; focus in/out reports
    if (start_full) enterFull();
    welcome();
    var ed = Editor{ .text = text_mem };
    editor = &ed;
    session.loadHistory(&ed.hist);
    while (true) {
        setMode(false);
        const line = if (cmd_n > 0) heldCommand() else ed.read() orelse return 0;
        setMode(true);
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) continue;
        if (text[0] == '/') if (command(text)) |quit| {
            if (quit) return 0;
            continue;
        };
        if (text[0] == '!') {
            shell(text[1..]);
            continue;
        }
        var msg = Buf.init(text.len + (1 << 20));
        defer msg.free();
        msg.add(text);
        attach(text, &msg);
        agent.user(msg.items());
        runAgent(&ed);
        if (screen.on) ui.raw("") else out("\n");
    }
}

/// The project folder with ~ for $HOME.
fn homeDir(ob: []u8) []const u8 {
    const dir = session.start_cwd;
    const home = sys.getenv("HOME") orelse "";
    if (home.len > 1 and std.mem.startsWith(u8, dir, home)) return std.fmt.bufPrint(ob, "~{s}", .{dir[home.len..]}) catch dir;
    return dir;
}

/// The checked-out branch (or short commit) of the git repo holding the project, read
/// from .git/HEAD; "" outside a repo.
fn gitBranch(ob: []u8) []const u8 {
    const root = agent.projectRoot(session.start_cwd);
    var pb: [4300]u8 = undefined;
    var fb: [512]u8 = undefined;
    var gb: [512]u8 = undefined;
    var head: []const u8 = sys.readFile(std.fmt.bufPrint(&pb, "{s}/.git/HEAD", .{root}) catch return "", &fb) catch blk: {
        // a worktree or submodule: .git is a file naming the real git dir
        const g = sys.readFile(std.fmt.bufPrint(&pb, "{s}/.git", .{root}) catch return "", &gb) catch return "";
        if (!std.mem.startsWith(u8, g, "gitdir: ")) return "";
        const gd = std.mem.trim(u8, g[8..], " \r\n");
        var qb: [4300]u8 = undefined;
        const p = if (gd.len > 0 and gd[0] == '/') std.fmt.bufPrint(&qb, "{s}/HEAD", .{gd}) else std.fmt.bufPrint(&qb, "{s}/{s}/HEAD", .{ root, gd });
        break :blk sys.readFile(p catch return "", &fb) catch return "";
    };
    head = std.mem.trim(u8, head, " \r\n");
    const ref = "ref: refs/heads/";
    const name = if (std.mem.startsWith(u8, head, ref)) head[ref.len..] else head[0..@min(head.len, 7)];
    const n = @min(name.len, ob.len);
    @memcpy(ob[0..n], name[0..n]);
    return ob[0..n];
}

/// What awl is pointed at, shown once at startup. AWL_WELCOME=off keeps it to one line.
fn welcome() void {
    var b = Buf.init(16 << 10);
    defer b.free();
    var db: [4096]u8 = undefined;
    const dir = homeDir(&db);
    var gb: [128]u8 = undefined;
    const br = gitBranch(&gb);
    const m = ui.muted();
    const r = ui.plain();
    if (sys.getenv("AWL_WELCOME")) |v| if (std.mem.eql(u8, v, "off")) {
        b.print("{s}awl · {s} · {s} · /help", .{ m, agent.cfg.model, dir });
        return ui.raw(b.items());
    };
    b.print("{s}\x1b[1mawl{s}{s} " ++ @import("main.zig").version ++ " · {s}{s}{s}", .{ ui.accent(), r, m, ui.fg(), agent.cfg.model, m });
    if (agent.ctx_limit > 0) b.print(" · {d}k context", .{agent.ctx_limit / 1000});
    b.print(" · mode {s}{s}{s}", .{ modeColor(), @tagName(tools.mode), m });
    ui.raw(b.items());
    b.reset();
    var rest = Buf.init(4096); // what follows the folder; the folder gets the rest of the row
    defer rest.free();
    if (br.len > 0) rest.print(" · ⎇ {s}", .{br});
    if (agent.n_agents_md > 0) rest.print(" · {d} AGENTS.md", .{agent.n_agents_md});
    if (agent.n_skills > 0) rest.print(" · {d} skill{s}", .{ agent.n_skills, if (agent.n_skills == 1) "" else "s" });
    const sx = @import("sandbox.zig");
    rest.print(" · {s}", .{if (sx.on) (if (sx.net) "sandboxed" else "sandboxed, offline") else "no sandbox"});
    const rest_w = std.unicode.utf8CountCodepoints(rest.items()) catch rest.len;
    const room = @as(usize, sys.termCols()) -| (rest_w + 1);
    const short = tailCols(dir, @max(room, 12));
    b.print("{s}{s}{s}{s}", .{ m, if (short.len < dir.len) "…" else "", short, rest.items() });
    ui.raw(b.items());
    if (agent.n_msgs <= 1) { // a fresh start: offer the last conversation held here
        var one: [1]session.Entry = undefined;
        const l = session.list(session.start_cwd, &one);
        if (l.len > 0) {
            const pr = l[0].prompt();
            const pc = cutCols(pr, @as(usize, sys.termCols()) -| 50);
            b.reset();
            var ab: [32]u8 = undefined;
            b.print("{s}last here {s}: “{s}{s}” · /resume 1 or awl -c", .{ m, l[0].age(&ab), pc, if (pc.len < pr.len) "…" else "" });
            ui.raw(b.items());
        }
    }
    b.reset();
    b.print("{s}Enter send · Esc stop · @file · !cmd · /help", .{m});
    ui.raw(b.items());
}

fn modeColor() []const u8 {
    return switch (tools.mode) {
        .auto => ui.muted(),
        .ask => ui.yellow(),
        .plan => ui.accent(),
    };
}

/// The end of path `s` in at most `w` columns, starting after a '/' when it is cut (the
/// caller shows "…" in front).
fn tailCols(s: []const u8, w: usize) []const u8 {
    const n = std.unicode.utf8CountCodepoints(s) catch s.len;
    if (n <= w) return s;
    var i: usize = 0;
    var skip = n - (w -| 1); // leave a column for the "…"
    while (skip > 0 and i < s.len) : (skip -= 1) i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    const t = s[@min(i, s.len)..];
    return if (std.mem.indexOfScalar(u8, t, '/')) |k| t[k..] else t;
}

test "tailCols keeps the end of a path" {
    try std.testing.expectEqualStrings("~/Work/awl", tailCols("~/Work/awl", 20));
    try std.testing.expectEqualStrings("/demo/proj", tailCols("/tmp/claude-1000/scratchpad/demo/proj", 14));
}

/// `s` cut to at most `w` columns (counting UTF-8 sequences as one column each).
fn cutCols(s: []const u8, w: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (cols == w) return s[0..i];
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        cols += 1;
    }
    return s[0..@min(i, s.len)];
}

/// The status line under the prompt. AWL_STATUS picks the items, in order, from
/// model, ctx, mode, branch, dir, session (default "model,ctx,mode,branch"); "off" hides it.
var status_items: []const u8 = "model,ctx,mode,branch";
var branch_b: [128]u8 = undefined;
var branch: []const u8 = "";

fn statusOn() bool {
    return status_items.len > 0 and !std.mem.eql(u8, status_items, "off");
}

fn footer(b: *Buf, w: usize) void {
    const m = ui.muted();
    const start = b.len;
    var cols: usize = 0;
    var it = std.mem.tokenizeScalar(u8, status_items, ',');
    var first = true;
    var item_b: [512]u8 = undefined;
    while (it.next()) |name0| {
        const name = std.mem.trim(u8, name0, " ");
        const eq = std.mem.eql;
        var color: []const u8 = m;
        const text: []const u8 = if (eq(u8, name, "model")) cutCols(agent.cfg.model, 32) //
            else if (eq(u8, name, "mode")) blk: {
                color = modeColor();
                break :blk @tagName(tools.mode);
            } else if (eq(u8, name, "branch")) (if (branch.len > 0) std.fmt.bufPrint(&item_b, "⎇ {s}", .{branch}) catch "" else "") //
            else if (eq(u8, name, "dir")) homeDir(&item_b) //
            else if (eq(u8, name, "session")) std.fs.path.basename(session.path) //
            else if (eq(u8, name, "ctx")) blk: {
                const k = @as(f64, @floatFromInt(agent.ctx_tokens)) / 1000;
                if (agent.ctx_limit == 0) break :blk if (agent.ctx_tokens == 0) "" else std.fmt.bufPrint(&item_b, "ctx {d:.1}k", .{k}) catch "";
                const pct = agent.ctx_tokens * 100 / agent.ctx_limit;
                // amber once old tool output starts being trimmed (60%), red near compaction (80%)
                color = if (pct >= 80) ui.red() else if (pct >= 60) ui.yellow() else m;
                break :blk std.fmt.bufPrint(&item_b, "ctx {d}% of {d}k", .{ pct, agent.ctx_limit / 1000 }) catch "";
            } else "";
        if (text.len == 0) continue;
        const sep: usize = if (first) 0 else 3;
        const tw = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (cols + sep + tw > w) break;
        if (!first) b.print("{s} · ", .{m});
        b.add(color);
        b.add(text);
        cols += sep + tw;
        first = false;
    }
    if (b.len > start) b.add(ui.plain());
}

/// Run the agent with type-ahead on; then send whatever was queued, and leave any
/// unsent draft in the editor.
fn runAgent(ed: *Editor) void {
    hist = &ed.hist;
    ui.busy = true;
    defer ui.busy = false;
    tools.ask = &askUser;
    defer tools.ask = null;
    sys.tick = &pump;
    agent.steer = &takeQueued;
    defer {
        sys.tick = null;
        agent.steer = null;
        ui.draft = "";
        ui.queued = 0;
        ui.held = "";
    }
    var o: agent.Outcome = .done;
    var secs: f64 = 0;
    while (true) {
        o = agent.run();
        secs += agent.run_secs;
        pump();
        if (o != .done or q_count == 0) break;
        const t = takeQueued().?;
        ui.userEcho(t);
        agent.user(t);
    }
    if (!focused and secs >= 15 and o != .cancelled) notify(o, secs);
    // Interrupted: nothing auto-sends; queued text and the draft go back to the prompt.
    var n: usize = 0;
    for ([_][]const u8{ q_mem[0..q_n], if (q_n > 0 and draft_n > 0) "\n" else "", draft_mem[0..draft_n] }) |part| {
        const k = @min(part.len, ed.text.len - n);
        @memcpy(ed.text[n .. n + k], part[0..k]);
        n += k;
    }
    ed.preset = n;
    // Keys the type-ahead does not use (arrows, Home, ...) and a half-read escape
    // sequence go to the editor as if typed now.
    if (esc != .none) {
        replayAdd(&[_]u8{27});
        if (esc == .seq) {
            replayAdd("[");
            replayAdd(ta_seq[0..@min(seq_n, ta_seq.len)]);
        }
    }
    @memcpy(ed.in[0..replay_n], replay[0..replay_n]);
    ed.in_n = replay_n;
    ed.in_i = 0;
    ed.pasting = ta_paste;
    replay_n = 0;
    q_n = 0;
    q_count = 0;
    draft_n = 0;
    esc = .none;
    ta_paste = false;
}

var replay: [256]u8 = undefined;
var replay_n: usize = 0;
fn replayAdd(s: []const u8) void {
    const k = @min(s.len, replay.len - replay_n);
    @memcpy(replay[replay_n .. replay_n + k], s[0..k]);
    replay_n += k;
}

var focused = true; // from the terminal's focus reports (CSI I / CSI O), when it sends them

/// A long turn finished while you were in another window: desktop notification
/// (notify-send, as Omarchy's mako shows them), and a bell for the terminal's urgency hint.
fn notify(o: agent.Outcome, secs: f64) void {
    out("\x07");
    var mb: [160]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&mb, "{s} after {d:.0}s", .{ if (o == .done) "finished" else "stopped", secs }) catch return;
    // fork twice: the middle child exits at once and is waited for, so no zombie is left
    const pid = linux.fork();
    if (pid != 0) {
        var st: u32 = 0;
        _ = linux.wait4(@intCast(pid), &st, 0, null);
        return;
    }
    if (linux.fork() != 0) linux.exit(0);
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    _ = linux.dup2(@intCast(devnull), 0);
    _ = linux.dup2(@intCast(devnull), 1);
    _ = linux.dup2(@intCast(devnull), 2);
    sys.unblockAll();
    var env: [1024]?[*:0]const u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/notify-send", "-a", "awl", "awl", msg };
    _ = linux.execve("/usr/bin/notify-send", &argv, sys.childEnvp(sys.envp, &env));
    linux.exit(0);
}

// Largest prompt (typed, pasted, or queued while the agent runs). These live in .bss: no binary size, no RSS until touched.
// They used to be 64 KiB (editor), 8 KiB (draft) and 16 KiB (queue) and silently cut longer pastes.
const input_cap = 4 << 20;

// Type-ahead while the agent runs: keys are read on each tick, never blocking.
var draft_mem: *[input_cap]u8 = undefined; // these three: lazy mmaps, see bigBuffersLazy
var draft_n: usize = 0;
var q_mem: *[input_cap]u8 = undefined;

/// The three 4 MiB input buffers as lazy anonymous mappings outside .bss: with THP "always" a .bss this
/// big was backed by 2 MB pages at load (idle RSS 4.4 MB instead of ~0.3 MB). Called first thing in main.
pub fn bigBuffersLazy() void {
    for ([_]**[input_cap]u8{ &draft_mem, &q_mem, &text_mem }) |slot| {
        const rc = linux.mmap(null, input_cap, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) @panic("mmap");
        _ = linux.madvise(@ptrFromInt(rc), input_cap, linux.MADV.NOHUGEPAGE);
        slot.* = @ptrFromInt(rc);
    }
}
var q_n: usize = 0;
var q_count: usize = 0;
var esc: enum { none, esc, seq } = .none;
var ta_seq: [16]u8 = undefined;
var seq_n: usize = 0;
var ta_paste = false;

var hist: ?*Buf = null; // the editor's history: queued messages are added to it

/// Approval for a command or file change (ask and plan modes): y / Enter, n, and in
/// ask mode a = allow this and everything after (switches to auto).
fn askUser() tools.Answer {
    pump(); // keys typed before the question belong to the draft, not the answer
    ui.ask(if (tools.mode == .ask) "  allow? y/n · a = all from now on (auto mode) " else "  allow? y/n ");
    ui.drawNow();
    while (true) {
        var p = [2]linux.pollfd{
            .{ .fd = sys.stdin, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = sys.sigfd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = sys.check(linux.poll(&p, 2, -1)) catch continue;
        if (p[1].revents != 0) {
            sys.drainSignals();
            ui.answered("stopped");
            return .cancel;
        }
        var b: [16]u8 = undefined;
        const n = sys.read(sys.stdin, &b) catch 0;
        if (n == 0) return .cancel;
        if (b[0] == 27 and n == 1) {
            ui.answered("stopped");
            return .cancel;
        }
        switch (b[0]) {
            'y', 'Y', '\r' => {
                ui.answered("allowed");
                return .yes;
            },
            'n', 'N' => {
                ui.answered("declined");
                return .no;
            },
            'a', 'A' => {
                ui.answered(if (tools.mode == .ask) "allowed · mode is now auto" else "allowed");
                return .always;
            },
            else => {},
        }
    }
}

fn takeQueued() ?[]const u8 {
    if (q_count == 0) return null;
    const t = q_mem[0..q_n];
    if (hist) |h| {
        h.add(t);
        h.byte(0);
        session.appendHistory(t);
    }
    q_n = 0;
    q_count = 0;
    ui.queued = 0;
    return t;
}

fn pump() void {
    var b: [1024]u8 = undefined;
    var got_any = false;
    while (true) {
        var p = [1]linux.pollfd{.{ .fd = sys.stdin, .events = linux.POLL.IN, .revents = 0 }};
        if ((sys.check(linux.poll(&p, 1, 0)) catch 0) == 0) break;
        const n = sys.read(sys.stdin, &b) catch 0;
        if (n == 0) break;
        keylog(b[0..n]);
        got_any = true;
        for (b[0..n]) |c| key(c);
    }
    // A lone Esc (nothing followed it within a tick) interrupts, like Ctrl-C.
    if (!got_any and esc == .esc) {
        esc = .none;
        _ = linux.kill(linux.getpid(), .INT);
    }
    ui.draft = draft_mem[0..draft_n];
    ui.queued = q_count;
    ui.tick();
}

fn key(c: u8) void {
    switch (esc) {
        .esc => {
            esc = if (c == '[' or c == 'O') .seq else .none;
            seq_n = 0;
            if (c == '\r') addDraft("\n"); // Alt-Enter
            return;
        },
        .seq => {
            if (seq_n < ta_seq.len) ta_seq[seq_n] = c;
            seq_n += 1;
            if (c >= 0x40 and c <= 0x7e) {
                esc = .none;
                const s = ta_seq[0..@min(seq_n, ta_seq.len)];
                if (std.mem.eql(u8, s, "I") or std.mem.eql(u8, s, "O")) {
                    focused = s[0] == 'I';
                } else if (std.mem.eql(u8, s, "200~")) {
                    ta_paste = true;
                } else if (std.mem.eql(u8, s, "201~")) {
                    ta_paste = false;
                } else if (scrollKey(s) or s[0] == '<') {
                    // scrolled (or a mouse click): not for the editor
                } else {
                    replayAdd("\x1b[");
                    replayAdd(s);
                }
            }
            return;
        },
        .none => {},
    }
    switch (c) {
        27 => esc = .esc,
        '\r' => if (ta_paste) addDraft("\n") else queueDraft(),
        '\t' => if (ta_paste) addDraft("\t") else replayAdd("\t"), // completion runs in the editor
        '\n' => addDraft("\n"),
        127, 8 => {
            while (draft_n > 0) {
                draft_n -= 1;
                if ((draft_mem[draft_n] & 0xC0) != 0x80) break;
            }
            ui.draft_changed = true;
        },
        21 => { // Ctrl-U
            draft_n = 0;
            ui.draft_changed = true;
        },
        else => if (c >= 32 or c == '\t' or c >= 0x80) addDraft(&[_]u8{c}),
    }
}

fn addDraft(s: []const u8) void {
    const k = @min(s.len, draft_mem.len - draft_n);
    @memcpy(draft_mem[draft_n .. draft_n + k], s[0..k]);
    draft_n += k;
    ui.draft_changed = true;
}

// A /command or !command typed during a run waits for the turn to end, then runs.
var cmd_mem: [1024]u8 = undefined;
var cmd_n: usize = 0;
var cmd_out: [1024]u8 = undefined;

fn heldCommand() []const u8 {
    const n = cmd_n;
    cmd_n = 0;
    @memcpy(cmd_out[0..n], cmd_mem[0..n]);
    ui.userEcho(cmd_out[0..n]);
    if (hist) |h| {
        h.add(cmd_out[0..n]);
        h.byte(0);
    }
    session.appendHistory(cmd_out[0..n]);
    return cmd_out[0..n];
}

fn queueDraft() void {
    const t = std.mem.trim(u8, draft_mem[0..draft_n], " \t\n");
    if (t.len == 0) return;
    if ((t[0] == '/' or t[0] == '!') and t.len <= cmd_mem.len and std.mem.indexOfScalar(u8, t, '\n') == null) {
        @memcpy(cmd_mem[0..t.len], t);
        cmd_n = t.len;
        draft_n = 0;
        ui.draft_changed = true;
        ui.held = cmd_mem[0..cmd_n];
        return;
    }
    const sep: []const u8 = if (q_n > 0) "\n\n" else "";
    if (q_n + sep.len + t.len > q_mem.len) return;
    @memcpy(q_mem[q_n .. q_n + sep.len], sep);
    q_n += sep.len;
    @memcpy(q_mem[q_n .. q_n + t.len], t);
    q_n += t.len;
    q_count += 1;
    draft_n = 0;
    ui.draft_changed = true;
}

/// `!cmd`: run it, show the output, and pass both to the model with the next message.
fn shell(cmd: []const u8) void {
    const c = std.mem.trim(u8, cmd, " ");
    if (c.len == 0) return;
    var zb = Buf.init(c.len + 1);
    defer zb.free();
    zb.add(c);
    zb.byte(0);
    var o = Buf.init(64 << 10);
    defer o.free();
    ui.tool("!", c);
    const ok = tools.userShell(zb.items()[0..c.len :0], &o) catch false;
    ui.toolOutput(o.items(), ok);
    if (agent.pending_note.len > 0) agent.pending_note.add("\n");
    agent.pending_note.print("[The user ran `{s}` in the shell:\n{s}\n]", .{ c, std.mem.trimEnd(u8, o.items()[0..@min(o.len, 16 << 10)], "\n") });
}

/// `@path` words: append each small text file to the message, so the model has it now.
fn attach(text: []const u8, msg: *Buf) void {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    var n: usize = 0;
    while (it.next()) |w0| {
        if (w0.len < 2 or w0[0] != '@') continue;
        const w = std.mem.trimEnd(u8, w0[1..], ".,;:!?)\"'");
        var fb: [32 << 10]u8 = undefined;
        const body = sys.readFile(w, &fb) catch continue; // not a file: leave the word as text
        if (body.len == fb.len or std.mem.indexOfScalar(u8, body, 0) != null) {
            ui.note("@{s}: too large or binary to attach; the model can read it", .{w});
            continue;
        }
        msg.print("\n\n<file path=\"{s}\">\n{s}{s}</file>", .{ w, body, if (body.len > 0 and body[body.len - 1] != '\n') "\n" else "" });
        tools.files_read.note(w);
        ui.note("attached {s} ({d} lines)", .{ w, std.mem.count(u8, body, "\n") });
        n += 1;
        if (n == 16) break;
    }
}

/// Returns null if `text` is not a known command, true to quit.
fn command(text: []const u8) ?bool {
    const eq = std.mem.eql;
    if (eq(u8, text, "/quit") or eq(u8, text, "/exit")) return true;
    if (eq(u8, text, "/clear") or eq(u8, text, "/new")) {
        agent.clear();
        ui.clearPlan();
        session.restart();
        ui.note("new conversation", .{});
    } else if (eq(u8, text, "/resume") or std.mem.startsWith(u8, text, "/resume ")) {
        var ents: [40]session.Entry = undefined;
        const l = session.list(session.start_cwd, &ents);
        var arg = std.mem.trim(u8, text[7..], " ");
        var nb: [8]u8 = undefined;
        if (arg.len == 0 and editor != null) {
            if (l.len == 0) {
                ui.note("no saved sessions for this folder", .{});
                return false;
            }
            const k = resumePicker(l) orelse return false;
            arg = std.fmt.bufPrint(&nb, "{d}", .{k + 1}) catch return false;
        }
        if (arg.len == 0) {
            if (l.len == 0) {
                ui.note("no saved sessions for this folder", .{});
                return false;
            }
            for (l, 1..) |*e, k| {
                var ab: [32]u8 = undefined;
                ui.note("{d:>2}  {s:<10}  {s}{s}", .{ k, e.age(&ab), e.prompt(), if (std.mem.eql(u8, e.file(), std.fs.path.basename(session.path))) "  (this one)" else "" });
            }
            ui.note("/resume N to open one", .{});
        } else {
            const k = std.fmt.parseInt(usize, arg, 10) catch 0;
            if (k == 0 or k > l.len) {
                ui.note("no session {s}; /resume lists them", .{arg});
                return false;
            }
            var pb: [512]u8 = undefined;
            const p = session.pathOf(&l[k - 1], &pb) orelse return false;
            agent.clear();
            ui.clearPlan();
            session.close();
            const n = agent.resume_(p) catch {
                ui.err("cannot read {s}", .{p});
                session.restart();
                return false;
            };
            ui.note("resumed {d} messages · {s}", .{ n, l[k - 1].prompt() });
        }
    } else if (eq(u8, text, "/copy") or eq(u8, text, "/copy code")) {
        const all = ui.reply.items();
        const t = if (text.len > 5) ui.lastCodeBlock(all) orelse "" else std.mem.trim(u8, all, "\n");
        if (t.len == 0) {
            ui.note("{s}", .{if (text.len > 5) "no code block in the last reply" else "nothing to copy yet"});
        } else {
            ui.clipboard(t);
            ui.note("copied {d} lines to the clipboard", .{std.mem.count(u8, std.mem.trimEnd(u8, t, "\n"), "\n") + 1});
        }
    } else if (eq(u8, text, "/undo")) {
        var o = Buf.init(64 << 10);
        defer o.free();
        if (tools.undoLast(&o) == 0) {
            ui.note("nothing to undo (changes made by commands are not tracked)", .{});
        } else {
            const list = std.mem.trimEnd(u8, o.items(), "\n");
            ui.note("{s}", .{list});
            agent.pending_note.print("[The user ran /undo. Your file changes from the previous turn were reverted:\n{s}\nThe files are back to how they were before that turn.]", .{list});
        }
    } else if (eq(u8, text, "/mode") or std.mem.startsWith(u8, text, "/mode ")) {
        const arg = std.mem.trim(u8, text[5..], " ");
        if (arg.len > 0) {
            tools.mode = std.meta.stringToEnum(tools.Mode, arg) orelse {
                ui.note("modes: auto (run everything), ask (approve commands and edits), plan (read-only)", .{});
                return false;
            };
            agent.mode_note = switch (tools.mode) {
                .plan => "[Plan mode is on: files are read-only. Investigate, then propose a plan; the user will switch modes to let you carry it out.]",
                .ask => "[Mode is now ask: you may change files and run commands; each one needs the user's approval.]",
                .auto => "[Mode is now auto: you may change files and run commands.]",
            };
        }
        ui.note("mode: {s}", .{@tagName(tools.mode)});
    } else if (eq(u8, text, "/model") or std.mem.startsWith(u8, text, "/model ")) {
        const arg = std.mem.trim(u8, text[6..], " ");
        if (arg.len == 0 and editor != null) {
                modelPicker();
                return false;
            }
        if (arg.len > 0) switchModel(arg, 0) else ui.note("model: {s}  (/model NAME to switch)", .{agent.cfg.model});
    } else if (eq(u8, text, "/compact")) {
        if (!agent.compactNow()) ui.note("nothing to compact yet", .{});
    } else if (eq(u8, text, "/context")) {
        var o = Buf.init(64 << 10);
        defer o.free();
        o.print("context: {d:.1}k", .{@as(f64, @floatFromInt(agent.ctx_tokens)) / 1000});
        if (agent.ctx_limit > 0) o.print(" of {d}k ({d}%)", .{ agent.ctx_limit / 1000, agent.ctx_tokens * 100 / agent.ctx_limit });
        o.print(" · {d} messages · system prompt + tools {d:.1} KB · mode {s}", .{ agent.n_msgs, @as(f64, @floatFromInt(agent.systemBytes())) / 1024, @tagName(tools.mode) });
        if (tools.files_changed.n > 0) {
            o.add("\nchanged: ");
            for (0..tools.files_changed.n) |i| o.print("{s}{s}", .{ if (i > 0) ", " else "", tools.files_changed.buf[i][0..tools.files_changed.len[i]] });
        }
        if (tools.files_read.n > 0) {
            o.add("\nread: ");
            for (0..tools.files_read.n) |i| o.print("{s}{s}", .{ if (i > 0) ", " else "", tools.files_read.buf[i][0..tools.files_read.len[i]] });
        }
        ui.note("{s}", .{o.items()});
    } else if (eq(u8, text, "/full")) {
        if (screen.on) leaveFull() else {
            enterFull();
            ui.note("full screen · PgUp/PgDn or the wheel scroll · Shift-drag selects · /full again to leave", .{});
        }
    } else if (eq(u8, text, "/expand")) {
        ui.expand();
    } else if (eq(u8, text, "/theme")) {
        ui.loadTheme();
        ui.note("theme reloaded", .{});
    } else if (eq(u8, text, "/help")) {
        var pb: [4096]u8 = undefined;
        const home = sys.getenv("HOME") orelse "";
        const sp = session.path;
        const spath = if (home.len > 1 and std.mem.startsWith(u8, sp, home)) std.fmt.bufPrint(&pb, "~{s}", .{sp[home.len..]}) catch sp else sp;
        ui.note(
            \\keys
            \\  Enter send · Alt-Enter or Ctrl-J newline · ↑↓ history · Ctrl-R search
            \\  Tab completes; after @ or / it opens a picker · Ctrl-P switch model
            \\  Ctrl-O shows a long draft, or the last tool output · Ctrl-L clears
            \\  Ctrl-C clears the line (twice quits) · Ctrl-D quits
            \\while it works
            \\  type and Enter to queue a message · Esc or Ctrl-C stops
            \\in a message
            \\  @file attaches a file · !cmd runs a command (the model sees it too)
            \\commands
            \\  /new  /resume  /model  /mode auto|ask|plan  /undo  /compact  /context
            \\  /copy  /copy code  /expand  /full  /theme  /quit
            \\session {s}
        , .{spath});
    } else return null;
    return false;
}

// ---- pickers: a filtered list chosen with the arrow keys ----

var editor: ?*Editor = null; // set in the interactive prompt; pickers read keys through it

const max_items = 4096;

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// 4: the last path part of `s` starts with `q`; 3: contains it; 2: `s` contains it;
/// 1: its letters appear in order; 0: no match. Case is ignored.
fn score(s: []const u8, q: []const u8) u3 {
    if (q.len == 0) return 4;
    const base = if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
    if (std.ascii.startsWithIgnoreCase(base, q)) return 4;
    if (std.ascii.indexOfIgnoreCase(base, q) != null) return 3;
    if (std.ascii.indexOfIgnoreCase(s, q) != null) return 2;
    var j: usize = 0;
    for (s) |c| {
        if (j < q.len and lower(c) == lower(q[j])) j += 1;
    }
    return if (j == q.len) 1 else 0;
}

/// Show `items` under `title`; typing filters, ↑↓ (or Tab, Ctrl-N/P) move, Enter picks,
/// Esc or Ctrl-C cancels. Returns the index into `items`. Draws where the cursor is and
/// erases itself before returning. `start`: the item selected first (with no query);
/// `paths`: among equal matches, shorter paths first.
const PickOpts = struct { start: usize = 0, paths: bool = false };

fn pick(title: []const u8, items: []const []const u8, query: []const u8, opts: PickOpts) ?usize {
    const ed = editor orelse return null;
    if (items.len == 0) return null;
    setMode(false);
    defer setMode(true);
    var q: [128]u8 = undefined;
    var qn = @min(query.len, q.len);
    @memcpy(q[0..qn], query[0..qn]);
    var shown: [max_items]u16 = undefined;
    var sc: [max_items]u3 = undefined;
    var sel: usize = if (query.len == 0) @min(opts.start, items.len - 1) else 0;
    var top: usize = 0;
    var cur_row: usize = 0; // the cursor's row in the drawn block (the query line)
    var drawn = false;
    var b = Buf.init(64 << 10);
    defer b.free();
    if (screen.on) { // room at the foot of the screen
        const top_row = @as(usize, sys.termRows()) -| @min(@as(usize, 12), @as(usize, sys.termRows()) -| 2);
        b.print("\x1b[{d};1H\x1b[J\x1b[?25h", .{top_row});
        out(b.items());
    }
    while (true) {
        // filter: name matches first, then path matches, then in-order letter matches
        var n: usize = 0;
        const all = items[0..@min(items.len, max_items)];
        for (all, 0..) |it, i| sc[i] = score(it, q[0..qn]);
        for ([_]u3{ 4, 3, 2, 1 }) |want| {
            const tier = n;
            for (all, 0..) |_, i| if (sc[i] == want) {
                shown[n] = @intCast(i);
                n += 1;
            };
            if (opts.paths and qn > 0) { // src/calc.py before src/__pycache__/calc.cpython-314.pyc
                const C = struct {
                    fn lt(its: []const []const u8, x: u16, y: u16) bool {
                        return its[x].len < its[y].len or (its[x].len == its[y].len and x < y);
                    }
                };
                std.sort.pdq(u16, shown[tier..n], all, C.lt);
            }
        }
        sel = @min(sel, n -| 1);
        const vis = @min(@as(usize, 10), @max(@as(usize, sys.termRows()) -| 4, 1));
        if (sel < top) top = sel;
        if (sel >= top + vis) top = sel + 1 - vis;
        const w = @as(usize, sys.termCols()) -| 3;
        b.reset();
        if (drawn and cur_row > 0) b.print("\x1b[{d}A", .{cur_row});
        b.add("\r\x1b[J");
        b.print("{s}{s} · {d} of {d} · ↑↓ Enter · Esc{s}\r\n", .{ ui.muted(), title, n, items.len, ui.plain() });
        b.print("{s}› {s}{s}", .{ ui.accent(), ui.plain(), q[0..qn] });
        var row: usize = 1;
        for (shown[top..@min(n, top + vis)], top..) |ix, k| {
            const it = cutCols(items[ix], w);
            if (k == sel) b.print("\r\n{s}▸ {s}{s}", .{ ui.accent(), it, ui.plain() }) else b.print("\r\n{s}  {s}{s}", .{ ui.muted(), it, ui.plain() });
            row += 1;
        }
        if (n == 0) {
            b.print("\r\n{s}  no match{s}", .{ ui.muted(), ui.plain() });
            row += 1;
        }
        // park the cursor after the query
        if (row > 1) b.print("\x1b[{d}A", .{row - 1});
        b.print("\r\x1b[{d}C", .{2 + qn});
        cur_row = 1;
        drawn = true;
        out(b.items());

        const c = ed.byte() orelse 3;
        var pick_it = false;
        var cancel = false;
        switch (c) {
            '\r' => pick_it = true,
            3, 7 => cancel = true, // Ctrl-C, Ctrl-G
            '\t', 14 => sel += 1, // Tab, Ctrl-N
            16 => sel -|= 1, // Ctrl-P
            127, 8 => while (qn > 0) {
                qn -= 1;
                if ((q[qn] & 0xC0) != 0x80) break;
            },
            21 => qn = 0, // Ctrl-U
            27 => {
                const c2 = ed.peekSoon() orelse 0;
                if (c2 != '[' and c2 != 'O') {
                    cancel = true;
                } else {
                    var seq: [8]u8 = undefined;
                    var k: usize = 0;
                    while (ed.byte()) |x| {
                        if (k < seq.len) seq[k] = x;
                        k += 1;
                        if (x >= 0x40 and x <= 0x7e) break;
                    }
                    const sq = seq[0..@min(k, seq.len)];
                    if (std.mem.eql(u8, sq, "A")) sel -|= 1 //
                    else if (std.mem.eql(u8, sq, "B")) sel += 1 //
                    else if (std.mem.eql(u8, sq, "5~")) sel -|= vis //
                    else if (std.mem.eql(u8, sq, "6~")) sel += vis;
                }
            },
            else => if (c >= 32 and qn < q.len) {
                q[qn] = c;
                qn += 1;
                sel = 0;
                top = 0;
            },
        }
        if (pick_it or cancel) {
            b.reset();
            if (cur_row > 0) b.print("\x1b[{d}A", .{cur_row});
            b.add("\r\x1b[J");
            out(b.items());
            if (cancel or n == 0) return null;
            return shown[sel];
        }
    }
}

/// /resume without a number: choose from this folder's sessions.
fn resumePicker(l: []session.Entry) ?usize {
    var text = Buf.init(64 << 10);
    defer text.free();
    var names: [64][]const u8 = undefined;
    var ends: [64]usize = undefined;
    for (l, 0..) |*e, k| {
        var ab: [32]u8 = undefined;
        text.print("{s:<11} {s}{s}", .{ e.age(&ab), e.prompt(), if (std.mem.eql(u8, e.file(), std.fs.path.basename(session.path))) "  (this one)" else "" });
        ends[k] = text.len;
    }
    var start: usize = 0;
    for (l, 0..) |_, k| {
        names[k] = text.items()[start..ends[k]];
        start = ends[k];
    }
    return pick("resume a conversation from this folder", names[0..l.len], "", .{});
}

/// /model without a name (and Ctrl-P without AWL_MODELS): choose from the server's list.
fn modelPicker() void {
    var ids = Buf.init(1 << 20);
    defer ids.free();
    var infos: [1024]llm.ModelInfo = undefined;
    const l = llm.models(agent.cfg, &ids, &infos) catch return ui.note("could not list models at {s}", .{agent.cfg.url.host});
    if (l.len < 2) return ui.note("model: {s} (the only one the server lists; /model NAME sets another)", .{agent.cfg.model});
    var text = Buf.init(1 << 20);
    defer text.free();
    var names: [1024][]const u8 = undefined;
    var ends: [1024]usize = undefined;
    var cur: usize = 0;
    for (l, 0..) |m, k| {
        text.add(m.id);
        if (m.ctx > 0) text.print("  {d}k", .{m.ctx / 1000});
        if (std.mem.eql(u8, m.id, agent.cfg.model)) {
            text.add("  (current)");
            cur = k;
        }
        ends[k] = text.len;
    }
    var start: usize = 0;
    for (l, 0..) |_, k| {
        names[k] = text.items()[start..ends[k]];
        start = ends[k];
    }
    const k = pick("switch model", names[0..l.len], "", .{ .start = cur }) orelse return;
    switchModel(l[k].id, l[k].ctx);
}

/// Switch model. `ctx` 0: ask the server for this model's window (kept as is when it
/// does not say), so trimming and compaction follow the new model.
fn switchModel(id: []const u8, ctx: u64) void {
    agent.setModel(id);
    if (ctx > 0) {
        agent.ctx_limit = ctx;
    } else {
        var ids = Buf.init(1 << 20);
        defer ids.free();
        var infos: [1024]llm.ModelInfo = undefined;
        const l = llm.models(agent.cfg, &ids, &infos) catch &.{};
        for (l) |m| if (std.mem.eql(u8, m.id, agent.cfg.model) and m.ctx > 0) {
            agent.ctx_limit = m.ctx;
        };
    }
    ui.note("model: {s}", .{agent.cfg.model});
}

/// Ctrl-P: the next model in AWL_MODELS (comma-separated), or the model picker.
fn cycleModel() void {
    const list = sys.getenv("AWL_MODELS") orelse return modelPicker();
    var it = std.mem.tokenizeScalar(u8, list, ',');
    var first: ?[]const u8 = null;
    var take_next = false;
    while (it.next()) |m0| {
        const m = std.mem.trim(u8, m0, " ");
        if (first == null) first = m;
        if (take_next) return switchModel(m, 0);
        take_next = std.mem.eql(u8, m, agent.cfg.model);
    }
    if (first) |m| switchModel(m, 0);
}

test "picker ranking" {
    try std.testing.expectEqual(@as(u3, 4), score("src/tui.zig", "TUI"));
    try std.testing.expectEqual(@as(u3, 3), score("src/my_tui.zig", "tui"));
    try std.testing.expectEqual(@as(u3, 2), score("tui/main.zig", "tui"));
    try std.testing.expectEqual(@as(u3, 1), score("tests/unit/i.py", "tui"));
    try std.testing.expectEqual(@as(u3, 0), score("README.md", "tui"));
    try std.testing.expectEqual(@as(u3, 4), score("anything", ""));
}

const commands = [_][]const u8{
    "/help", "/new", "/resume", "/model", "/mode", "/undo", "/copy", "/copy code", "/expand", "/context", "/compact", "/full", "/theme", "/quit",
};

/// Piped stdin: one prompt per line.
fn plain() u8 {
    var buf = Buf.init(16 << 20);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = sys.read(sys.stdin, &chunk) catch 0;
        if (n > 0) buf.add(chunk[0..n]);
        while (std.mem.indexOfScalar(u8, buf.items(), '\n') orelse (if (n == 0 and buf.len > 0) buf.len else null)) |i| {
            const text = std.mem.trim(u8, buf.items()[0..i], " \t\r");
            if (text.len > 0) {
                if (text[0] == '/' and command(text) == true) return 0;
                if (text[0] != '/') {
                    agent.user(text);
                    _ = agent.run();
                }
            }
            const rest = buf.items()[@min(i + 1, buf.len)..];
            std.mem.copyForwards(u8, buf.items()[0..rest.len], rest);
            buf.truncate(rest.len);
        }
        if (n == 0) return 0;
    }
}

/// AWL_DEBUG_KEYS=<file>: append every raw input chunk (escaped) so a keyboard or paste problem shows exactly what the terminal sent.
pub var keylog_path: ?[]const u8 = null;
var keylog_fd: ?sys.fd_t = null;
var keylog_t0: u64 = 0;
var keylog_buf = Buf.init(1 << 16);
fn keylog(bytes: []const u8) void {
    const path = keylog_path orelse return;
    if (keylog_fd == null) {
        keylog_fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch {
            keylog_path = null;
            return;
        };
        keylog_t0 = sys.nowNs();
    }
    const hex = "0123456789abcdef";
    keylog_buf.truncate(0);
    keylog_buf.print("+{d}ms n={d} ", .{ (sys.nowNs() - keylog_t0) / std.time.ns_per_ms, bytes.len });
    for (bytes) |c| switch (c) {
        0x1b => keylog_buf.add("\\e"),
        '\r' => keylog_buf.add("\\r"),
        '\n' => keylog_buf.add("\\n"),
        '\\' => keylog_buf.add("\\\\"),
        0x20...0x5b, 0x5d...0x7e => keylog_buf.byte(c),
        else => {
            keylog_buf.add("\\x");
            keylog_buf.byte(hex[c >> 4]);
            keylog_buf.byte(hex[c & 15]);
        },
    };
    keylog_buf.byte('\n');
    sys.writeAll(keylog_fd.?, keylog_buf.items()) catch {};
}

const prompt = "› ";
const indent = "  ";

// Big buffers cost nothing in the binary or until touched (text_mem: see bigBuffersLazy).
var text_mem: *[input_cap]u8 = undefined;
var in_mem: [4096]u8 = undefined;

const Editor = struct {
    text: *[input_cap]u8 = undefined, // text_mem
    dropped: usize = 0, // bytes of the current paste that did not fit
    len: usize = 0,
    cur: usize = 0,
    row: usize = 0, // terminal row of the cursor, relative to the prompt's first row
    hist: Buf = Buf.init(4 << 20), // entries separated by 0
    hpos: ?usize = null, // byte offset of the history entry being shown
    pasting: bool = false,
    ctrl_c: bool = false,
    in: *[4096]u8 = &in_mem,
    in_n: usize = 0,
    in_i: usize = 0,
    preset: usize = 0, // text[0..preset] starts the next prompt (type-ahead left over)
    search_q: [256]u8 = undefined,
    search_n: ?usize = null, // Ctrl-R query length while searching
    search_pos: usize = 0, // search continues in hist before this offset
    foot: bool = true, // draw the status line under the input

    fn byte(self: *Editor) ?u8 {
        if (self.in_i == self.in_n) {
            // A Ctrl-C pressed just as a turn ended arrives as SIGINT: treat it as the key.
            if (screen.on) { // full screen: redraw when the window changes size
                var size = [2]u16{ sys.termRows(), sys.termCols() };
                while (!(http.wait(sys.stdin, 250) catch return 3)) {
                    const now = [2]u16{ sys.termRows(), sys.termCols() };
                    if (now[0] != size[0] or now[1] != size[1]) {
                        size = now;
                        fullDraw();
                    }
                }
            } else _ = http.wait(sys.stdin, -1) catch return 3;
            const n = sys.read(sys.stdin, self.in) catch 0;
            if (n == 0) return null;
            keylog(self.in[0..n]);
            self.in_n = n;
            self.in_i = 0;
        }
        self.in_i += 1;
        return self.in[self.in_i - 1];
    }

    /// Next byte if one is already buffered or arrives within 30 ms (to split ESC from Alt-x).
    fn peekSoon(self: *Editor) ?u8 {
        if (self.in_i == self.in_n) {
            const ready = http.wait(sys.stdin, 30) catch false;
            if (!ready) return null;
        }
        return self.byte();
    }

    fn read(self: *Editor) ?[]const u8 {
        self.len = self.preset;
        self.cur = self.preset;
        self.preset = 0;
        self.row = 0;
        self.hpos = null;
        self.foot = true;
        ui.themeTick();
        branch = gitBranch(&branch_b);
        if (sys.getenv("AWL_STATUS")) |v| status_items = v;
        self.render();
        while (true) {
            const c = self.byte() orelse return null;
            if (c != 3) self.ctrl_c = false;
            if (c != 18) self.search_n = null;
            switch (c) {
                '\r' => {
                    if (self.pasting) {
                        self.insert("\n");
                        continue;
                    }
                    self.cur = self.len;
                    if (!screen.on and self.layout(sys.termCols(), 0, 0, null).rows > @max(@as(usize, sys.termRows()) -| 3, 3)) {
                        self.showAll(false);
                    } else self.leave();
                    const t = self.text[0..self.len];
                    if (std.mem.trim(u8, t, " \n").len > 0) {
                        self.hist.add(t);
                        self.hist.byte(0);
                        session.appendHistory(t);
                    }
                    return t;
                },
                '\n' => self.insert("\n"),
                3 => { // Ctrl-C
                    if (self.len > 0) {
                        self.len = 0;
                        self.cur = 0;
                    } else if (self.ctrl_c) {
                        self.leave();
                        return null;
                    } else {
                        self.ctrl_c = true;
                        self.cur = 0;
                        self.leave();
                        ui.note("Ctrl-C again to quit", .{});
                        self.row = 0;
                    }
                },
                4 => if (self.len == 0) {
                    self.leave();
                    return null;
                } else self.delete(),
                1 => self.cur = self.lineStart(),
                5 => self.cur = self.lineEnd(),
                21 => { // Ctrl-U: kill to line start
                    const s = self.lineStart();
                    self.cut(s, self.cur);
                },
                11 => self.cut(self.cur, self.lineEnd()), // Ctrl-K
                23 => { // Ctrl-W: delete word back
                    var s = self.cur;
                    while (s > 0 and self.text[s - 1] == ' ') s -= 1;
                    while (s > 0 and self.text[s - 1] != ' ' and self.text[s - 1] != '\n') s -= 1;
                    self.cut(s, self.cur);
                },
                18 => self.search(), // Ctrl-R
                16 => { // Ctrl-P: next favorite model (AWL_MODELS) or the model picker
                    self.aside();
                    cycleModel();
                },
                '\t' => if (self.pasting) self.insert("\t") else self.complete(),
                15 => if (self.len == 0) { // Ctrl-O: the whole draft, or the last tool output
                    out("\r\x1b[J");
                    ui.expand();
                    self.row = 0;
                } else if (screen.on) {
                    ui.note("{s}", .{self.text[0..self.len]});
                    ui.note("── end of draft ──", .{});
                } else self.showAll(true),
                12 => { // Ctrl-L
                    out("\x1b[H\x1b[2J");
                    self.row = 0;
                },
                127, 8 => if (self.cur > 0) {
                    const s = self.prev(self.cur);
                    self.cut(s, self.cur);
                },
                27 => self.escape(),
                else => if (c >= 32 or c == '\t') {
                    self.insert(&[_]u8{c});
                    // take the rest of a UTF-8 sequence in one go
                    const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
                    var k: usize = 1;
                    while (k < n) : (k += 1) self.insert(&[_]u8{self.byte() orelse 0});
                },
            }
            if (self.in_i == self.in_n) self.render(); // batch redraws (pastes)
        }
    }

    fn escape(self: *Editor) void {
        const c = self.peekSoon() orelse return;
        if (c == '\r') return self.insert("\n"); // Alt-Enter
        if (c != '[' and c != 'O') return;
        var seq: [16]u8 = undefined;
        var n: usize = 0;
        while (self.byte()) |b| {
            if (n < seq.len) seq[n] = b;
            n += 1;
            if (b >= 0x40 and b <= 0x7e) break;
        }
        const s = seq[0..@min(n, seq.len)];
        const eq = std.mem.eql;
        if (scrollKey(s)) return;
        if (eq(u8, s, "200~")) {
            self.pasting = true;
            self.dropped = 0;
        } //
        else if (eq(u8, s, "201~")) self.pasteEnd() //
        else if (eq(u8, s, "D")) self.cur = self.prev(self.cur) //
        else if (eq(u8, s, "C")) self.cur = self.next(self.cur) //
        else if (eq(u8, s, "H") or eq(u8, s, "1~")) self.cur = self.lineStart() //
        else if (eq(u8, s, "F") or eq(u8, s, "4~")) self.cur = self.lineEnd() //
        else if (eq(u8, s, "3~")) self.delete() //
        else if (eq(u8, s, "I")) focused = true //
        else if (eq(u8, s, "O")) focused = false //
        else if (eq(u8, s, "A")) self.history(-1) //
        else if (eq(u8, s, "B")) self.history(1);
    }

    fn pasteEnd(self: *Editor) void {
        self.pasting = false;
        if (self.dropped > 0) {
            ui.note("input limit reached: {d} KB of the paste were not added (limit {d} MB)", .{ (self.dropped + 1023) / 1024, input_cap >> 20 });
            self.dropped = 0;
        }
    }

    fn insert(self: *Editor, s: []const u8) void {
        if (self.len + s.len > self.text.len) {
            self.dropped += s.len;
            return;
        }
        std.mem.copyBackwards(u8, self.text[self.cur + s.len .. self.len + s.len], self.text[self.cur..self.len]);
        @memcpy(self.text[self.cur .. self.cur + s.len], s);
        self.len += s.len;
        self.cur += s.len;
    }

    fn cut(self: *Editor, a: usize, b: usize) void {
        std.mem.copyForwards(u8, self.text[a .. self.len - (b - a)], self.text[b..self.len]);
        self.len -= b - a;
        self.cur = a;
    }

    fn delete(self: *Editor) void {
        if (self.cur < self.len) self.cut(self.cur, self.next(self.cur));
    }

    fn prev(self: *Editor, i: usize) usize {
        var j = i -| 1;
        while (j > 0 and (self.text[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }
    fn next(self: *Editor, i: usize) usize {
        if (i >= self.len) return self.len;
        var j = i + 1;
        while (j < self.len and (self.text[j] & 0xC0) == 0x80) j += 1;
        return j;
    }
    fn lineStart(self: *Editor) usize {
        return if (std.mem.lastIndexOfScalar(u8, self.text[0..self.cur], '\n')) |i| i + 1 else 0;
    }
    fn lineEnd(self: *Editor) usize {
        return if (std.mem.indexOfScalarPos(u8, self.text[0..self.len], self.cur, '\n')) |i| i else self.len;
    }

    /// Tab after `@part`: complete a file or directory name; list the choices when several.
    fn complete(self: *Editor) void {
        var s = self.cur;
        while (s > 0 and self.text[s - 1] != ' ' and self.text[s - 1] != '\n') s -= 1;
        const word = self.text[s..self.cur];
        if (s == 0 and word.len > 0 and word[0] == '/') return self.completeCommand(word);
        if (word.len == 0 or word[0] != '@') return self.insert("\t");
        const p = word[1..];
        const slash = std.mem.lastIndexOfScalar(u8, p, '/');
        const dir = if (slash) |i| p[0 .. i + 1] else "";
        const base = if (slash) |i| p[i + 1 ..] else p;
        const dfd = sys.open(if (dir.len > 0) dir else ".", .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch {
            if (!self.filePicker(s, p)) out("\x07");
            return;
        };
        defer sys.close(dfd);
        var names: [4096]u8 = undefined; // matches, each followed by '/' (directory) or ' '
        var nn: usize = 0;
        var ends: [256]u16 = undefined; // end of each match in `names` (after its mark)
        var count: usize = 0;
        var common: []const u8 = "";
        var b: [8192]u8 align(8) = undefined;
        while (true) {
            const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
            if (got == 0) break;
            var off: usize = 0;
            while (off < got) {
                const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
                off += e.reclen;
                const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off - e.reclen + @offsetOf(linux.dirent64, "name")])), 0);
                if (!std.mem.startsWith(u8, name, base) or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
                if (nn + name.len + 1 > names.len or count == ends.len) continue;
                const start = nn;
                @memcpy(names[nn .. nn + name.len], name);
                nn += name.len;
                names[nn] = if (e.type == linux.DT.DIR) '/' else ' ';
                nn += 1;
                common = if (count == 0) names[start .. start + name.len] else common[0..commonLen(common, name)];
                ends[count] = @intCast(nn);
                count += 1;
            }
        }
        if (count == 0) {
            if (!self.filePicker(s, p)) out("\x07");
            return;
        }
        if (count == 1) {
            self.insert(common[base.len..]);
            self.insert(names[nn - 1 .. nn]); // '/' for a directory, ' ' for a file
            return;
        }
        if (common.len > base.len) return self.insert(common[base.len..]);
        // several choices and nothing to add: pick from the project's files
        if (self.filePicker(s, p)) return;
        if (self.row > 0) out(std.fmt.bufPrint(&b, "\x1b[{d}A", .{self.row}) catch "");
        out("\r\x1b[J");
        self.row = 0;
        var list = Buf.init(nn * 2 + 64);
        defer list.free();
        var from: usize = 0;
        for (ends[0..count], 0..) |end, k| {
            if (k == 40) {
                list.print("… {d} more", .{count - k});
                break;
            }
            const e = names[from..end];
            list.add(if (e[e.len - 1] == '/') e else e[0 .. e.len - 1]); // keep '/' on directories
            list.add("  ");
            from = end;
        }
        ui.note("{s}", .{list.items()});
    }

    /// The project's files (fd), filtered by what follows the @; the choice replaces
    /// the word at `s`. False when fd is missing (the caller lists the folder instead).
    fn filePicker(self: *Editor, s: usize, typed: []const u8) bool {
        var o = Buf.init(1 << 20);
        defer o.free();
        if (!tools.listFiles(&o)) return false;
        var names = Buf.init(20001 * @sizeOf([]const u8));
        defer names.free();
        var it = std.mem.splitScalar(u8, o.items(), '\n');
        var n: usize = 0;
        while (it.next()) |l| {
            if (l.len == 0 or l[0] == '[' or std.mem.eql(u8, l, "no files found")) continue;
            const slot = names.extend(@sizeOf([]const u8));
            if (slot.len < @sizeOf([]const u8)) break;
            @as(*align(1) []const u8, @ptrCast(slot.ptr)).* = if (std.mem.startsWith(u8, l, "./")) l[2..] else l;
            n += 1;
        }
        const list = @as([*]align(1) const []const u8, @ptrCast(names.items().ptr))[0..n];
        var q: [128]u8 = undefined;
        const qn = @min(typed.len, q.len);
        @memcpy(q[0..qn], typed[0..qn]); // the picker draws over the prompt; keep a copy
        var al: [max_items][]const u8 = undefined;
        const k = @min(n, al.len);
        for (list[0..k], 0..) |x, i| al[i] = x;
        self.aside();
        const choice = pick("attach a file", al[0..k], q[0..qn], .{ .paths = true }) orelse return true;
        const path = al[choice];
        self.cut(s, self.cur);
        self.insert("@");
        self.insert(path);
        self.insert(" ");
        return true;
    }

    /// Tab after "/x" at the start: complete a command, or pick one.
    fn completeCommand(self: *Editor, word: []const u8) void {
        var only: ?[]const u8 = null;
        var count: usize = 0;
        for (commands) |c| if (std.mem.startsWith(u8, c, word)) {
            only = c;
            count += 1;
        };
        const choice = if (count == 1) only.? else blk: {
            var q: [64]u8 = undefined;
            const qn = @min(word.len, q.len);
            @memcpy(q[0..qn], word[0..qn]);
            self.aside();
            const k = pick("commands", &commands, q[0..qn], .{}) orelse return;
            break :blk commands[k];
        };
        self.cut(0, self.cur);
        self.insert(choice);
        const takes_arg = for ([_][]const u8{ "/resume", "/model", "/mode" }) |a| {
            if (std.mem.eql(u8, a, choice)) break true;
        } else false;
        if (takes_arg) self.insert(" ");
    }

    fn commonLen(a: []const u8, b: []const u8) usize {
        var i: usize = 0;
        while (i < a.len and i < b.len and a[i] == b[i]) i += 1;
        return i;
    }

    /// Ctrl-R: the newest history entry containing what was typed; again for older ones.
    fn search(self: *Editor) void {
        const h = self.hist.items();
        if (self.search_n == null) {
            const q = std.mem.trim(u8, self.text[0..self.len], " \n");
            const k = @min(q.len, self.search_q.len);
            @memcpy(self.search_q[0..k], q[0..k]);
            self.search_n = k;
            self.search_pos = h.len;
        }
        const q = self.search_q[0..self.search_n.?];
        var end = self.search_pos; // entries are "text\0"; walk back from `end`
        while (end > 0) {
            const stop = end - 1; // the 0 ending this entry
            const start = if (std.mem.lastIndexOfScalar(u8, h[0..stop], 0)) |i| i + 1 else 0;
            const e = h[start..stop];
            end = start;
            if (std.mem.indexOf(u8, e, q) != null and !std.mem.eql(u8, e, self.text[0..self.len])) {
                @memcpy(self.text[0..e.len], e);
                self.len = e.len;
                self.cur = e.len;
                self.hpos = start;
                self.search_pos = start;
                return;
            }
        }
        out("\x07"); // no older match
    }

    /// Walk history entries (newest last). dir -1 = older, +1 = newer.
    fn history(self: *Editor, dir: i2) void {
        const h = self.hist.items();
        if (h.len == 0) return;
        var pos: usize = self.hpos orelse h.len;
        if (dir < 0) {
            if (pos == 0) return;
            const end = pos - 1; // the 0 terminating the previous entry
            pos = if (std.mem.lastIndexOfScalar(u8, h[0..end], 0)) |i| i + 1 else 0;
        } else {
            if (self.hpos == null) return;
            const end = std.mem.indexOfScalarPos(u8, h, pos, 0).? + 1;
            if (end >= h.len) {
                self.hpos = null;
                self.len = 0;
                self.cur = 0;
                return;
            }
            pos = end;
        }
        self.hpos = pos;
        const e = h[pos..std.mem.indexOfScalarPos(u8, h, pos, 0).?];
        @memcpy(self.text[0..e.len], e);
        self.len = e.len;
        self.cur = e.len;
    }

    /// Redraw the prompt in place and park the cursor. Input taller than the screen
    /// shows a window around the cursor (a cursor-up past the top would spill copies
    /// into the scrollback); Ctrl-O prints all of it, and so does sending it.
    /// Take the prompt off the screen so something can print in its place; the next
    /// render draws it again below.
    fn aside(self: *Editor) void {
        if (screen.on) return; // the picker places itself; notes go to the conversation
        var b: [16]u8 = undefined;
        if (self.row > 0) out(std.fmt.bufPrint(&b, "\x1b[{d}A", .{self.row}) catch "");
        out("\r\x1b[J");
        self.row = 0;
    }

    /// Done with this prompt: redraw it without the status line, move below it.
    fn leave(self: *Editor) void {
        if (screen.on) { // the message joins the conversation; the input box empties
            self.foot = false;
            if (std.mem.trim(u8, self.text[0..self.len], " \n").len > 0) ui.userEcho(self.text[0..self.len]);
            ui.drawNow();
            return;
        }
        self.foot = false;
        self.render();
        out("\r\n");
        self.foot = true;
    }

    fn render(self: *Editor) void {
        if (screen.on) return fullDraw();
        const w: usize = sys.termCols();
        const foot = self.foot and statusOn();
        const max_rows: usize = @max(@as(usize, sys.termRows()) -| (3 + @as(usize, @intFromBool(foot))), 3);
        const all = self.layout(w, 0, 0, null);
        var lo: usize = 0;
        var hi: usize = all.rows;
        if (all.rows > max_rows) { // window ending at the cursor's row or later
            hi = @min(all.rows, @max(all.cur_row + 1, max_rows - 1));
            lo = hi - (max_rows - 1);
        }
        var b = Buf.init(self.len * 2 + 4096);
        defer b.free();
        if (self.row > 0) b.print("\x1b[{d}A", .{self.row});
        b.add("\r\x1b[J");
        if (lo > 0) b.print("{s}  ↑ {d} more lines · Ctrl-O shows all{s}\r\n", .{ ui.muted(), lo, ui.plain() });
        const r = self.layout(w, lo, hi, &b);
        const top: usize = @intFromBool(lo > 0); // the header row
        var last = hi - 1 - lo + top; // screen row (from the prompt top) where output ended
        const cur = r.cur_row - lo + top;
        if (foot) {
            b.add("\r\n\x1b[K");
            footer(&b, w -| 1);
            last += 1;
        }
        if (last > cur) b.print("\x1b[{d}A", .{last - cur});
        b.add("\r");
        if (r.cur_col > 0) b.print("\x1b[{d}C", .{r.cur_col});
        self.row = cur;
        out(b.items());
    }

    /// Print the whole input as a plain block (scrolls normally), then a fresh prompt.
    fn showAll(self: *Editor, then_prompt: bool) void {
        var b = Buf.init(self.len * 2 + 4096);
        defer b.free();
        if (self.row > 0) b.print("\x1b[{d}A", .{self.row});
        b.add("\r\x1b[J");
        const all = self.layout(sys.termCols(), 0, std.math.maxInt(usize), &b);
        _ = all;
        b.add("\r\n");
        out(b.items());
        self.row = 0;
        if (then_prompt) {
            ui.note("── end of draft ({d} lines) ──", .{std.mem.count(u8, self.text[0..self.len], "\n") + 1});
            self.render();
        }
    }

    const Layout = struct { rows: usize, cur_row: usize, cur_col: usize };

    /// Walk the text as the terminal will wrap it. Rows in [lo, hi) are written to `b`
    /// (hi == 0 writes nothing). Returns the row count and the cursor position.
    fn layout(self: *Editor, w: usize, lo: usize, hi: usize, b: ?*Buf) Layout {
        var row: usize = 0;
        var col: usize = 2;
        var res = Layout{ .rows = 1, .cur_row = 0, .cur_col = 2 };
        const show = struct {
            fn in(r: usize, l: usize, h: usize) bool {
                return r >= l and r < h;
            }
        }.in;
        if (b) |o| if (show(0, lo, hi)) {
            o.add(ui.accent());
            o.add(prompt);
            o.add(ui.plain());
        };
        var i: usize = 0;
        while (i <= self.len) {
            if (i == self.cur) {
                res.cur_row = row;
                res.cur_col = col;
            }
            if (i == self.len) break;
            const c = self.text[i];
            if (c == '\n') {
                row += 1;
                col = 2;
                if (b) |o| if (show(row, lo, hi)) o.add(if (row > lo) "\r\n" ++ indent else indent);
                i += 1;
                continue;
            }
            const n = @min(std.unicode.utf8ByteSequenceLength(c) catch 1, self.len - i);
            if (b) |o| if (show(row, lo, hi)) o.add(if (c == '\t') " " else self.text[i .. i + n]);
            i += n;
            col += 1;
            if (col == w) { // force the wrap now so positions stay exact; line up under the text
                row += 1;
                col = 2;
                if (b) |o| if (show(row, lo, hi)) o.add(if (row > lo) "\r\n" ++ indent else indent);
            }
        }
        res.rows = row + 1;
        return res;
    }
};
