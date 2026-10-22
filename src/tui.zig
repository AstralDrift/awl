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
    _ = linux.ioctl(sys.stdin, linux.T.CSETSW, @intFromPtr(&orig));
    out("\x1b[?2004l\x1b[0m");
}

fn out(s: []const u8) void {
    sys.writeAll(sys.stdout, s) catch {};
}

pub fn repl() u8 {
    if (!sys.isatty(sys.stdin) or !sys.isatty(sys.stdout)) return plain();
    have_orig = linux.errno(linux.ioctl(sys.stdin, linux.T.CGETS, @intFromPtr(&orig))) == .SUCCESS;
    defer restore();
    out("\x1b[?2004h"); // bracketed paste
    var cb: [4096]u8 = undefined;
    const rc = linux.getcwd(&cb, cb.len);
    var dir: []const u8 = if (linux.errno(rc) == .SUCCESS) std.mem.sliceTo(&cb, 0) else ".";
    const home = sys.getenv("HOME") orelse "";
    var tb: [4096]u8 = undefined;
    if (home.len > 1 and std.mem.startsWith(u8, dir, home)) dir = std.fmt.bufPrint(&tb, "~{s}", .{dir[home.len..]}) catch dir;
    ui.note("awl · {s} · {s}{s}{s} · /help", .{ agent.cfg.model, dir, if (tools.mode != .auto) " · mode " else "", if (tools.mode != .auto) @tagName(tools.mode) else "" });
    var ed = Editor{};
    while (true) {
        setMode(false);
        const line = ed.read() orelse return 0;
        setMode(true);
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) continue;
        if (text[0] == '/') if (command(text)) |quit| {
            if (quit) return 0;
            continue;
        };
        agent.user(text);
        runAgent(&ed);
        out("\n");
    }
}

/// Run the agent with type-ahead on; then send whatever was queued, and leave any
/// unsent draft in the editor.
fn runAgent(ed: *Editor) void {
    hist = &ed.hist;
    tools.ask = &askUser;
    defer tools.ask = null;
    sys.tick = &pump;
    agent.steer = &takeQueued;
    defer {
        sys.tick = null;
        agent.steer = null;
        ui.draft = "";
        ui.queued = 0;
    }
    while (true) {
        const o = agent.run();
        pump();
        if (o != .done or q_count == 0) break;
        const t = takeQueued().?;
        ui.userEcho(t);
        agent.user(t);
    }
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

// Type-ahead while the agent runs: keys are read on each tick, never blocking.
var draft_mem: [8192]u8 = undefined;
var draft_n: usize = 0;
var q_mem: [16384]u8 = undefined;
var q_n: usize = 0;
var q_count: usize = 0;
var esc: enum { none, esc, seq } = .none;
var ta_seq: [8]u8 = undefined;
var seq_n: usize = 0;
var ta_paste = false;

var hist: ?*Buf = null; // the editor's history: queued messages are added to it

/// Approval for a command or file change (ask and plan modes): y / Enter, n, a = always.
fn askUser() tools.Answer {
    pump(); // keys typed before the question belong to the draft, not the answer
    ui.ask("  allow? y/n, a = always ");
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
                if (std.mem.eql(u8, s, "200~")) {
                    ta_paste = true;
                } else if (std.mem.eql(u8, s, "201~")) {
                    ta_paste = false;
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

fn queueDraft() void {
    const t = std.mem.trim(u8, draft_mem[0..draft_n], " \t\n");
    if (t.len == 0) return;
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

/// Returns null if `text` is not a known command, true to quit.
fn command(text: []const u8) ?bool {
    const eq = std.mem.eql;
    if (eq(u8, text, "/quit") or eq(u8, text, "/exit")) return true;
    if (eq(u8, text, "/clear")) {
        agent.clear();
        ui.note("conversation cleared", .{});
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
    } else if (std.mem.startsWith(u8, text, "/mode")) {
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
    } else if (eq(u8, text, "/expand")) {
        ui.expand();
    } else if (eq(u8, text, "/theme")) {
        ui.loadTheme();
        ui.note("theme reloaded", .{});
    } else if (eq(u8, text, "/help")) {
        ui.note("Enter send · Alt-Enter/Ctrl-J newline · ↑↓ history · Ctrl-C cancel/clear (twice to quit) · Ctrl-D quit\nWhile it works: type and Enter to queue a message for the next step · Esc or Ctrl-C to stop\nCtrl-O: show all of a long draft, or (empty prompt) the last tool output\n/undo  /mode auto|ask|plan  /copy  /copy code  /expand  /clear  /theme  /quit\nsession: {s}", .{session.path});
    } else return null;
    return false;
}

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

const prompt = "› ";
const indent = "  ";

// Big buffers live in .bss so they cost nothing in the binary or until touched.
var text_mem: [65536]u8 = undefined;
var in_mem: [4096]u8 = undefined;

const Editor = struct {
    text: *[65536]u8 = &text_mem,
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

    fn byte(self: *Editor) ?u8 {
        if (self.in_i == self.in_n) {
            // A Ctrl-C pressed just as a turn ended arrives as SIGINT: treat it as the key.
            _ = http.wait(sys.stdin, -1) catch return 3;
            const n = sys.read(sys.stdin, self.in) catch 0;
            if (n == 0) return null;
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
        self.render();
        while (true) {
            const c = self.byte() orelse return null;
            if (c != 3) self.ctrl_c = false;
            switch (c) {
                '\r' => {
                    if (self.pasting) {
                        self.insert("\n");
                        continue;
                    }
                    self.cur = self.len;
                    if (self.layout(sys.termCols(), 0, 0, null).rows > @max(@as(usize, sys.termRows()) -| 3, 3)) {
                        self.showAll(false);
                    } else {
                        self.render();
                        out("\r\n");
                    }
                    const t = self.text[0..self.len];
                    if (std.mem.trim(u8, t, " \n").len > 0) {
                        self.hist.add(t);
                        self.hist.byte(0);
                    }
                    return t;
                },
                '\n' => self.insert("\n"),
                3 => { // Ctrl-C
                    if (self.len > 0) {
                        self.len = 0;
                        self.cur = 0;
                    } else if (self.ctrl_c) {
                        out("\r\n");
                        return null;
                    } else {
                        self.ctrl_c = true;
                        self.cur = 0;
                        self.render();
                        out("\r\n");
                        ui.note("Ctrl-C again to quit", .{});
                        self.row = 0;
                    }
                },
                4 => if (self.len == 0) {
                    out("\r\n");
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
                15 => if (self.len == 0) { // Ctrl-O: the whole draft, or the last tool output
                    out("\r\x1b[J");
                    ui.expand();
                    self.row = 0;
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
        if (eq(u8, s, "200~")) self.pasting = true //
        else if (eq(u8, s, "201~")) self.pasting = false //
        else if (eq(u8, s, "D")) self.cur = self.prev(self.cur) //
        else if (eq(u8, s, "C")) self.cur = self.next(self.cur) //
        else if (eq(u8, s, "H") or eq(u8, s, "1~")) self.cur = self.lineStart() //
        else if (eq(u8, s, "F") or eq(u8, s, "4~")) self.cur = self.lineEnd() //
        else if (eq(u8, s, "3~")) self.delete() //
        else if (eq(u8, s, "A")) self.history(-1) //
        else if (eq(u8, s, "B")) self.history(1);
    }

    fn insert(self: *Editor, s: []const u8) void {
        if (self.len + s.len > self.text.len) return;
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
    fn render(self: *Editor) void {
        const w: usize = sys.termCols();
        const max_rows: usize = @max(@as(usize, sys.termRows()) -| 3, 3);
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
        const last = hi - 1 - lo + top; // screen row (from the prompt top) where output ended
        const cur = r.cur_row - lo + top;
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
            if (col == w) { // force the wrap now so positions stay exact
                row += 1;
                col = 0;
                if (b) |o| if (show(row, lo, hi) and row > lo) o.add("\r\n");
            }
        }
        res.rows = row + 1;
        return res;
    }
};
