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
    ui.note("awl · {s} · {s} · /help", .{ agent.cfg.model, session.path });
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
        _ = agent.run();
        out("\n");
    }
}

/// Returns null if `text` is not a known command, true to quit.
fn command(text: []const u8) ?bool {
    const eq = std.mem.eql;
    if (eq(u8, text, "/quit") or eq(u8, text, "/exit")) return true;
    if (eq(u8, text, "/clear")) {
        agent.clear();
        ui.note("conversation cleared", .{});
    } else if (eq(u8, text, "/theme")) {
        ui.loadTheme();
        ui.note("theme reloaded", .{});
    } else if (eq(u8, text, "/help")) {
        ui.note("Enter send · Alt-Enter/Ctrl-J newline · ↑↓ history · Ctrl-C cancel/clear (twice to quit) · Ctrl-D quit\n/clear  /theme  /quit", .{});
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
        self.len = 0;
        self.cur = 0;
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
                    self.render();
                    out("\r\n");
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

    /// Redraw the prompt in place and park the cursor.
    fn render(self: *Editor) void {
        const w: usize = sys.termCols();
        var b = Buf.init(self.len * 2 + 4096);
        defer b.free();
        if (self.row > 0) b.print("\x1b[{d}A", .{self.row});
        b.add("\r\x1b[J");
        b.add(ui.accent());
        b.add(prompt);
        b.add(ui.plain());
        var row: usize = 0;
        var col: usize = 2;
        var cur_row: usize = 0;
        var cur_col: usize = 2;
        var i: usize = 0;
        while (i <= self.len) {
            if (i == self.cur) {
                cur_row = row;
                cur_col = col;
            }
            if (i == self.len) break;
            const c = self.text[i];
            if (c == '\n') {
                b.add("\r\n" ++ indent);
                row += 1;
                col = 2;
                i += 1;
                continue;
            }
            const n = @min(std.unicode.utf8ByteSequenceLength(c) catch 1, self.len - i);
            b.add(if (c == '\t') " " else self.text[i .. i + n]);
            i += n;
            col += 1;
            if (col == w) { // force the wrap now so positions stay exact
                b.add("\r\n");
                row += 1;
                col = 0;
            }
        }
        if (row > cur_row) b.print("\x1b[{d}A", .{row - cur_row});
        b.add("\r");
        if (cur_col > 0) b.print("\x1b[{d}C", .{cur_col});
        self.row = cur_row;
        out(b.items());
    }
};
