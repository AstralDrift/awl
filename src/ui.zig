//! Inline terminal output. No alternate screen: the terminal keeps scrollback.
//! One-shot mode (-p) writes the answer to stdout and everything else to stderr.
const std = @import("std");
const sys = @import("sys.zig");

pub var quiet = false; // tests
pub var color = false; // stdout is a terminal
pub var oneshot = false;

// Theme: SGR sequences built from Omarchy's colors.toml.
const Sgr = struct { b: [24]u8 = undefined, n: usize = 0 };
var th = struct { accent: Sgr = .{}, fg: Sgr = .{}, muted: Sgr = .{}, red: Sgr = .{}, green: Sgr = .{}, yellow: Sgr = .{} }{};

fn sgr(s: *const Sgr) []const u8 {
    if (!color) return "";
    return s.b[0..s.n];
}
fn reset() []const u8 {
    return if (color) "\x1b[0m" else "";
}

fn setColor(s: *Sgr, hex: []const u8) void {
    const h = std.mem.trimStart(u8, hex, "#");
    if (h.len != 6) return;
    const v = std.fmt.parseInt(u24, h, 16) catch return;
    const out = std.fmt.bufPrint(&s.b, "\x1b[38;2;{d};{d};{d}m", .{ v >> 16, (v >> 8) & 0xff, v & 0xff }) catch return;
    s.n = out.len;
}

var theme_stamp: i64 = 0; // mtime (ns) of the colors.toml loaded last

fn themePath(pb: []u8) ?[]const u8 {
    const home = sys.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(pb, "{s}/.local/state/omarchy/current/theme/colors.toml", .{home}) catch null;
}

fn themeStamp(path: []const u8) i64 {
    var zb: [520]u8 = undefined;
    var st: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, sys.z(&zb, path), 0, .{ .MTIME = true }, &st);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    return st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
}

/// Reload the colors if Omarchy switched themes since the last load (one statx).
pub fn themeTick() void {
    var pb: [512]u8 = undefined;
    const p = themePath(&pb) orelse return;
    if (themeStamp(p) != theme_stamp) loadTheme();
}

/// Load the active Omarchy theme. Missing file → terminal default colors.
pub fn loadTheme() void {
    const fallback = .{ .{ &th.accent, "\x1b[34m" }, .{ &th.fg, "\x1b[39m" }, .{ &th.muted, "\x1b[90m" }, .{ &th.red, "\x1b[31m" }, .{ &th.green, "\x1b[32m" }, .{ &th.yellow, "\x1b[33m" } };
    inline for (fallback) |f| {
        @memcpy(f[0].b[0..f[1].len], f[1]);
        f[0].n = f[1].len;
    }
    var pb: [512]u8 = undefined;
    const path = themePath(&pb) orelse return;
    theme_stamp = themeStamp(path);
    var fb: [8192]u8 = undefined;
    const text = sys.readFile(path, &fb) catch return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.mem.eql(u8, k, "accent")) setColor(&th.accent, v);
        if (std.mem.eql(u8, k, "foreground")) setColor(&th.fg, v);
        if (std.mem.eql(u8, k, "muted")) setColor(&th.muted, v);
        if (std.mem.eql(u8, k, "dark_foreground")) setColor(&th.muted, v);
        if (std.mem.eql(u8, k, "red")) setColor(&th.red, v);
        if (std.mem.eql(u8, k, "green")) setColor(&th.green, v);
        if (std.mem.eql(u8, k, "yellow")) setColor(&th.yellow, v);
    }
}

pub fn accent() []const u8 {
    return sgr(&th.accent);
}
pub fn muted() []const u8 {
    return sgr(&th.muted);
}
pub fn yellow() []const u8 {
    return sgr(&th.yellow);
}
pub fn red() []const u8 {
    return sgr(&th.red);
}
pub fn green() []const u8 {
    return sgr(&th.green);
}
pub fn fg() []const u8 {
    return sgr(&th.fg);
}
pub fn plain() []const u8 {
    return reset();
}

// Output is staged in a small buffer and flushed once per call.
var ob: [8192]u8 = undefined;
var on: usize = 0;
pub var capture: ?*@import("buf.zig").Buf = null; // tests: collect output here instead
fn put(s: []const u8) void {
    if (live) { // the live area is on screen: clear it before real output
        live = false;
        var cb: [16]u8 = undefined;
        put(if (live_rows > 1) std.fmt.bufPrint(&cb, "\x1b[{d}A\r\x1b[J", .{live_rows - 1}) catch "\r\x1b[J" else "\r\x1b[K");
        live_rows = 0;
    }
    if (s.len > ob.len - on) flushTo(if (oneshot) sys.stderr else sys.stdout);
    if (s.len > ob.len) {
        sys.writeAll(if (oneshot) sys.stderr else sys.stdout, s) catch {};
        return;
    }
    @memcpy(ob[on .. on + s.len], s);
    on += s.len;
}
var last_out: u64 = 0;
fn flushTo(fd: sys.fd_t) void {
    if (on > 0) last_out = sys.nowNs();
    if (capture) |c| c.add(ob[0..on]) else if (screen.on) {
        screen.feed(ob[0..on]);
        on = 0;
        return requestDraw();
    } else if (!quiet) sys.writeAll(fd, ob[0..on]) catch {};
    on = 0;
}

const screen = @import("screen.zig");
/// Full-screen mode: draws the whole screen (set by tui).
pub var redraw: ?*const fn () void = null;
pub var busy = false; // a turn is running: full-screen mode shows the live area
var last_draw: u64 = 0;
var draw_pending = false;

/// Redraw now, or at the next tick when the last frame was under 30 ms ago.
fn requestDraw() void {
    const now = sys.nowNs();
    if (now -| last_draw < 30 * std.time.ns_per_ms) {
        draw_pending = true;
        return;
    }
    drawNow();
}

pub fn drawNow() void {
    const f = redraw orelse return;
    last_draw = sys.nowNs();
    draw_pending = false;
    f();
}

/// Full-screen mode: the live area as rows (separated by '\n'): the checklist and the
/// timer line with the reasoning tail and queue counts (the draft is in the input box).
pub fn liveRows(b: *@import("buf.zig").Buf, w: usize) void {
    var pb: [4096]u8 = undefined;
    const p = panel(&pb, w);
    var it = std.mem.splitSequence(u8, p, "\r\n");
    while (it.next()) |r| if (r.len > 0) {
        b.add(r);
        b.byte('\n');
    };
    var tb: [8192]u8 = undefined;
    var tr = std.mem.splitSequence(u8, thoughtRows(&tb, w), "\r\n");
    while (tr.next()) |r| if (r.len > 0) {
        b.add(r);
        b.byte('\n');
    };
    const secs = (sys.nowNs() - live_t0) / std.time.ns_per_s;
    b.print("{s}{s} {d}s", .{ muted(), if (thinking) "∴" else "⋯", secs });
    var cols: usize = 4 + std.fmt.count("{d}", .{secs});
    var fb: [64]u8 = undefined;
    b.add(formingLabel(&fb));
    if (queued > 0) {
        b.print(" · {d} queued", .{queued});
        cols += 11;
    }
    if (held.len > 0) {
        b.print(" · then {s}", .{held[0..@min(held.len, 40)]});
        cols += 8 + @min(held.len, 40);
    }
    b.add(reset());
}
fn flush() void {
    flushTo(if (oneshot) sys.stderr else sys.stdout);
}
var print_buf = @import("buf.zig").Buf.init(1 << 20);
fn print(comptime f: []const u8, a: anytype) void {
    print_buf.truncate(0); // keeps its pages: no syscall per line
    print_buf.print(f, a);
    put(print_buf.items());
}

// Stream state for one assistant turn.
var bol = true;
var fence = false;
var ticks: u8 = 0;
var thinking = false;
var think_start: u64 = 0;
var tail: [4096]u8 = undefined; // the newest reasoning text, for the live rows
var tail_n: usize = 0;
pub var think_rows: usize = 6; // AWL_THINK_ROWS: reasoning rows shown while the model thinks (0: timer only)
var thought_rows: usize = 0; // rows the last thoughtRows() wrote

pub fn reasoning(s: []const u8) void {
    if (!color or oneshot) return;
    if (!thinking) {
        thinking = true;
        think_start = sys.nowNs();
        tail_n = 0;
    }
    defer if (screen.on) requestDraw();
    for (s) |c0| {
        const c = if (c0 < 0x20 or c0 == 0x7f) ' ' else c0; // no control codes on the live line
        if (tail_n == tail.len) {
            std.mem.copyForwards(u8, tail[0 .. tail.len - 1024], tail[1024..]);
            tail_n -= 1024;
        }
        tail[tail_n] = c;
        tail_n += 1;
    }
    if (screen.on) return;
    const now = sys.nowNs();
    if (now -| last_live < 33 * std.time.ns_per_ms) return; // ~30 frames/s at most; tick() catches up
    last_live = now;
    flush();
    drawLive();
}
var last_live: u64 = 0;

/// The end of the reasoning, word-wrapped to `w` columns, as the last `think_rows` rows
/// ("\r\n" after each). Widths are counted in bytes: never more than the columns a row
/// really takes, so a row cannot spill onto a second line and break the redraw.
fn thoughtRows(b: []u8, w: usize) []const u8 {
    thought_rows = 0;
    const room = @min(think_rows, @as(usize, sys.termRows()) -| (panel_rows + 4));
    if (!thinking or room == 0 or w < 12) return b[0..0];
    const ww = w - 2;
    var st: usize = 0;
    while (st < tail_n and (tail[st] & 0xC0) == 0x80) st += 1; // utf-8 boundary
    if (tail_n == tail.len or st > 0) { // the buffer was shifted: start at a word
        while (st < tail_n and tail[st] != ' ') st += 1;
    }
    while (st < tail_n and tail[st] == ' ') st += 1;
    // row starts/ends in a ring of the newest `room` rows
    var rs: [64][2]usize = undefined;
    var nrows: usize = 0;
    var i = st;
    while (i < tail_n) {
        var end = @min(i + ww, tail_n);
        if (end < tail_n) { // break at the last space, else mid-word on a utf-8 boundary
            var sp = end;
            while (sp > i and tail[sp] != ' ') sp -= 1;
            if (sp > i) end = sp else while (end > i and (tail[end] & 0xC0) == 0x80) end -= 1;
            if (end == i) end = @min(i + ww, tail_n);
        }
        rs[nrows % rs.len] = .{ i, end };
        nrows += 1;
        i = end;
        while (i < tail_n and tail[i] == ' ') i += 1;
    }
    const show = @min(nrows, @min(room, rs.len));
    var n: usize = 0;
    var k = nrows - show;
    while (k < nrows) : (k += 1) {
        const r = rs[k % rs.len];
        const s = std.fmt.bufPrint(b[n..], "{s}  {s}{s}\r\n", .{ muted(), tail[r[0]..r[1]], reset() }) catch break;
        n += s.len;
        thought_rows += 1;
    }
    return b[0..n];
}

// Live area: while the model or a tool works and nothing else is printing, the
// model's checklist (if it keeps one) and one dim line with the elapsed time and
// whatever the user is typing (sent at the next step).
var live = false;
var live_rows: usize = 0; // rows the live area takes (the cursor is on the last)
var live_t0: u64 = 0;
pub var draft: []const u8 = ""; // text typed while the agent works (owned by tui)
pub var queued: usize = 0; // messages waiting for the next step
pub var draft_changed = false;
pub var held: []const u8 = ""; // a /command waiting for the turn to end

/// A new wait starts (model request or tool): restart the timer.
pub fn liveStart() void {
    live_t0 = sys.nowNs();
}

/// Called every ~200 ms while waiting. Redraws only at the start of a line.
pub fn tick() void {
    if (!color or oneshot or quiet or capture != null) return;
    if (screen.on) return drawNow(); // the timer, the draft, any output held back
    if (thinking) return drawLive(); // the timer runs on while the reasoning rows stand still
    if (!bol or on > 0) return;
    const now = sys.nowNs();
    const changed = draft_changed;
    draft_changed = false;
    // Streaming text: stay out of the way unless the user is typing.
    if (!changed and now -| last_out < 700 * std.time.ns_per_ms) return;
    if (!changed and (now - live_t0) < std.time.ns_per_s and queued == 0 and held.len == 0) return;
    drawLive();
}

fn drawLive() void {
    var b: [16384]u8 = undefined;
    var n: usize = 0;
    const secs = (sys.nowNs() - live_t0) / std.time.ns_per_s;
    const w = @as(usize, sys.termCols()) -| 1;
    // back to the top of the area drawn last time, then the checklist
    // one synchronized frame (DEC 2026; ignored where unsupported): no flicker while it repaints
    const top = if (live and live_rows > 1) (std.fmt.bufPrint(&b, "\x1b[?2026h\x1b[{d}A\r\x1b[J", .{live_rows - 1}) catch return) else (std.fmt.bufPrint(&b, "\x1b[?2026h\r\x1b[K", .{}) catch return);
    n = top.len;
    const rows = panel(b[n .. b.len - 9216], w);
    n += rows.len;
    const trows = thoughtRows(b[n .. b.len - 1024], w);
    n += trows.len;
    const head = std.fmt.bufPrint(b[n..], "{s}{s} {d}s", .{ muted(), if (thinking) "∴" else "⋯", secs }) catch return;
    n += head.len;
    var cols: usize = 4 + std.fmt.count("{d}", .{secs});
    const fl = formingLabel(b[n..]);
    n += fl.len;
    cols += fl.len;
    if (queued > 0) {
        const q = std.fmt.bufPrint(b[n..], " · {d} queued", .{queued}) catch "";
        n += q.len;
        cols += q.len;
    }
    if (held.len > 0) {
        const q = std.fmt.bufPrint(b[n..], " · then {s}", .{held[0..@min(held.len, 40)]}) catch "";
        n += q.len;
        cols += q.len;
    }
    if (draft.len > 0) {
        const p = std.fmt.bufPrint(b[n..], "{s}  › {s}", .{ reset(), sgr(&th.fg) }) catch "";
        n += p.len;
        cols += 4;
        // show the end of the draft, on one line
        const room = @min(w -| cols, b.len - n - 8);
        var start = draft.len -| room;
        while (start < draft.len and (draft[start] & 0xC0) == 0x80) start += 1;
        for (draft[start..]) |c| {
            b[n] = if (c == '\n') ' ' else c;
            n += 1;
        }
    }
    const r = reset();
    @memcpy(b[n .. n + r.len], r);
    n += r.len;
    const e = "\x1b[?2026l";
    @memcpy(b[n .. n + e.len], e);
    n += e.len;
    sys.writeAll(sys.stdout, b[0..n]) catch {};
    live = true;
    live_rows = panel_rows + thought_rows + 1;
}

// The model's checklist, from its latest todo call: one line per item, "[x] text".
var plan_b: [4096]u8 = undefined;
var plan_n: usize = 0;
var panel_rows: usize = 0; // rows the last panel() wrote

/// Forget the checklist (a new conversation).
pub fn clearPlan() void {
    plan_n = 0;
}

fn setPlan(text: []const u8) void {
    const body = std.mem.trimStart(u8, text[@import("tools.zig").todo_marker.len..], "\n");
    const end = std.mem.lastIndexOf(u8, body, "\n(") orelse body.len; // drop "(3/7 done)"
    plan_n = @min(end, plan_b.len);
    @memcpy(plan_b[0..plan_n], body[0..plan_n]);
}

/// The whole checklist after a todo call: ✓ done, ▸ in progress, ○ to do, – skipped.
fn checklist() void {
    const w = @as(usize, sys.termCols()) -| 4;
    var it = std.mem.splitScalar(u8, plan_b[0..plan_n], '\n');
    while (it.next()) |l| {
        if (l.len < 4) continue;
        const st: struct { []const u8, []const u8 } = switch (l[1]) {
            'x' => .{ sgr(&th.green), "✓" },
            '>' => .{ sgr(&th.accent), "▸" },
            '-' => .{ muted(), "–" },
            else => .{ muted(), "○" },
        };
        print("  {s}{s}{s} {s}{s}{s}\n", .{ st[0], st[1], reset(), if (l[1] == '>') sgr(&th.fg) else muted(), cut(l[4..], w), reset() });
    }
    flush();
}

fn panelRows() usize {
    var b: [4096]u8 = undefined;
    _ = panel(&b, 80);
    return panel_rows;
}

/// The checklist as it stands, compact: finished items folded into one count, then
/// the item in progress and the next few. Nothing once every item is finished.
fn panel(b: []u8, w: usize) []const u8 {
    panel_rows = 0;
    if (plan_n == 0 or !color or oneshot) return b[0..0];
    var done: usize = 0;
    var open: usize = 0;
    var it = std.mem.splitScalar(u8, plan_b[0..plan_n], '\n');
    while (it.next()) |l| {
        if (l.len < 4) continue;
        if (l[1] == 'x' or l[1] == '-') done += 1 else open += 1;
    }
    if (open == 0) return b[0..0];
    const max_open = @min(@as(usize, 4), @as(usize, sys.termRows()) -| 6);
    var n: usize = 0;
    if (done > 0) {
        const s = std.fmt.bufPrint(b[n..], "{s}  ✓ {d} done{s}\r\n", .{ sgr(&th.green), done, reset() }) catch return b[0..0];
        n += s.len;
        panel_rows += 1;
    }
    var shown: usize = 0;
    it = std.mem.splitScalar(u8, plan_b[0..plan_n], '\n');
    while (it.next()) |l| {
        if (l.len < 4 or l[1] == 'x' or l[1] == '-') continue;
        if (shown == max_open) {
            const s = std.fmt.bufPrint(b[n..], "{s}    … {d} more{s}\r\n", .{ muted(), open - shown, reset() }) catch break;
            n += s.len;
            panel_rows += 1;
            break;
        }
        const doing = l[1] == '>';
        const text = cut(l[4..], w -| 4);
        const s = std.fmt.bufPrint(b[n..], "{s}  {s} {s}{s}\r\n", .{ if (doing) sgr(&th.accent) else muted(), if (doing) "▸" else "○", text, reset() }) catch break;
        n += s.len;
        panel_rows += 1;
        shown += 1;
    }
    return b[0..n];
}

fn endThinking() void {
    if (!thinking) return;
    thinking = false;
    const secs = @as(f64, @floatFromInt(sys.nowNs() - think_start)) / 1e9;
    if (!screen.on) put(if (live) "" else "\r\x1b[K"); // put() clears a live area of any height
    print("{s}∴ thought {d:.1}s{s}\n", .{ muted(), secs, reset() });
}

var started = false; // has this message printed any text yet

// The newest assistant text and tool output, kept for /copy and /expand.
pub var reply = @import("buf.zig").Buf.init(4 << 20);
pub var last_tool = @import("buf.zig").Buf.init(1 << 20);

pub fn content(s0: []const u8) void {
    // Models often open with blank lines; drop them so replies start flush.
    const s = if (started) s0 else std.mem.trimStart(u8, s0, " \t\r\n");
    if (s.len == 0) return;
    if (!started) reply.reset();
    reply.add(s);
    started = true;
    endThinking();
    if (oneshot) {
        if (!quiet) sys.writeAll(sys.stdout, s) catch {};
        bol = s[s.len - 1] == '\n';
        return;
    }
    if (!color) {
        put(s);
        bol = s[s.len - 1] == '\n';
    } else for (s) |c| md(c);
    flush();
}

// Markdown-lite, one byte at a time so replies still stream: headings, **bold**,
// `code`, bullets and ``` fences. Markers at a line start are held until they are
// known (at most a few bytes); everything else prints at once.
var lead = true; // only indentation or a possible marker so far on this line
var pend: [12]u8 = undefined;
var pend_n: usize = 0;
var star = false; // one '*' held back: maybe the start of "**"
var bold = false;
var code = false; // inside `inline code`
var heading = false;

const Lead = enum { wait, heading, bullet, done, todo, fence, quote, table, text };

fn classify(p: []const u8, in_fence: bool) Lead {
    const s = std.mem.trimStart(u8, p, " ");
    if (s.len == 0) return .wait;
    if (std.mem.allEqual(u8, s, '`')) return if (s.len == 3) .fence else if (s.len < 3) .wait else .text;
    if (in_fence) return .text;
    if (s[0] == '#') {
        const h = std.mem.indexOfNone(u8, s, "#") orelse return if (s.len <= 6) .wait else .text;
        return if (h <= 6 and s[h] == ' ' and h + 1 == s.len) .heading else .text;
    }
    if (s[0] == '-' or s[0] == '*' or s[0] == '+') {
        if (s.len == 1) return .wait;
        if (std.mem.allEqual(u8, s, s[0])) return .wait; // maybe a rule (---), decided at the line end
        if (s[1] != ' ') return .text;
        // "- [x] " / "- [ ] ": a task item; "- " then anything else: a bullet
        const box = s[2..];
        if (box.len == 0) return .wait;
        if (box[0] != '[') return .bullet;
        if (box.len < 4) return if (box.len == 1 or box[1] == 'x' or box[1] == 'X' or box[1] == ' ') .wait else .bullet;
        if (box[2] == ']' and box[3] == ' ') return if (box[1] == ' ') .todo else if (box[1] == 'x' or box[1] == 'X') .done else .bullet;
        return .bullet;
    }
    if (s[0] == '|') return .table;
    if (s[0] == '>') return if (s.len == 1) .wait else if (s[1] == ' ') .quote else .text;
    return .text;
}

// Tables are held until they end, then printed with aligned columns: a bold header, a thin rule,
// two spaces between columns, inline markers dropped. Too wide for the terminal: printed as sent.
var tbl = @import("buf.zig").Buf.init(1 << 20);
var tline = false; // this line is a table row being collected

fn cellWidth(c: []const u8) usize {
    var n: usize = 0;
    for (c) |b| {
        if ((b & 0xC0) != 0x80 and b != '`' and b != '*') n += 1;
    }
    return n;
}

fn isRule(cell: []const u8) bool {
    const t = std.mem.trim(u8, cell, " :");
    return t.len > 0 and std.mem.allEqual(u8, t, '-');
}

fn flushTable() void {
    if (tbl.len == 0) return;
    defer tbl.reset();
    const text = tbl.items();
    var widths: [16]usize = .{0} ** 16;
    var ncols: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, std.mem.trim(u8, line, " "), "|"), '|');
        var k: usize = 0;
        var rule = true;
        while (cells.next()) |c| : (k += 1) {
            if (k == widths.len) return rawTable(text);
            if (!isRule(c)) rule = false;
            if (!isRule(c)) widths[k] = @max(widths[k], cellWidth(std.mem.trim(u8, c, " ")));
        }
        if (line.len > 0 and !rule) ncols = @max(ncols, k);
    }
    if (ncols == 0) return rawTable(text);
    // Fit the terminal: shrink the widest column one step at a time (never below 8); cells wrap at words.
    const avail = @as(usize, sys.termCols()) -| (2 + 2 * (ncols - 1) + 1);
    var sum: usize = 0;
    for (widths[0..ncols]) |w| sum += w;
    while (sum > avail) {
        var wi: usize = 0;
        for (widths[0..ncols], 0..) |w, k| if (w > widths[wi]) {
            wi = k;
        };
        if (widths[wi] <= 8) return tableRecords(text, ncols);
        widths[wi] -= 1;
        sum -= 1;
    }
    var total: usize = 2;
    for (widths[0..ncols]) |w| total += w + 2;
    it = std.mem.splitScalar(u8, text, '\n');
    var row: usize = 0;
    var cb: [8192]u8 = undefined; // this row's cells, markers dropped
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, std.mem.trim(u8, line, " "), "|"), '|');
        var peek = cells;
        var rule = true;
        while (peek.next()) |c| if (!isRule(c)) {
            rule = false;
        };
        if (rule) continue;
        var cell: [16][]const u8 = .{""} ** 16;
        var n: usize = 0;
        var k: usize = 0;
        while (cells.next()) |c0| : (k += 1) {
            if (k == ncols) break;
            const start_n = n;
            for (std.mem.trim(u8, c0, " ")) |b| if (b != '`' and b != '*' and n < cb.len) {
                cb[n] = b;
                n += 1;
            };
            cell[k] = cb[start_n..n];
        }
        while (true) { // one screen line per pass, each column taking its next wrapped piece
            var any = false;
            for (cell[0..ncols]) |c| if (c.len > 0) {
                any = true;
            };
            if (!any) break;
            put("  ");
            if (row == 0) put("\x1b[1m");
            for (cell[0..ncols], 0..) |*c, kk| {
                const piece = wrapPiece(c.*, widths[kk]);
                put(piece);
                c.* = std.mem.trimStart(u8, c.*[piece.len..], " ");
                if (kk + 1 < ncols) for (0..widths[kk] - textCols(piece) + 2) |_| put(" ");
            }
            if (row == 0) put(reset());
            put("\n");
        }
        if (row == 0) {
            put("  ");
            put(muted());
            for (0..total - 4) |_| put("─");
            put(reset());
            put("\n");
        }
        row += 1;
    }
}

fn textCols(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
    }
    return n;
}

/// The longest start of `s` that fits `w` columns, broken after a space when there is one.
fn wrapPiece(s: []const u8, w: usize) []const u8 {
    if (textCols(s) <= w) return s;
    var end: usize = 0;
    var c: usize = 0;
    var last_space: usize = 0;
    while (end < s.len) {
        var e = end + 1;
        while (e < s.len and (s[e] & 0xC0) == 0x80) e += 1;
        if (c + 1 > w) break;
        if (s[end] == ' ') last_space = end;
        c += 1;
        end = e;
    }
    return if (last_space > 0) s[0..last_space] else s[0..end];
}

/// A table too wide for the terminal: each row as a record, its first cell bold, then "Header: value" lines
/// that the terminal wraps. Readable at any width, unlike pipes broken across lines.
fn tableRecords(text: []const u8, ncols: usize) void {
    var head: [16][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '\n');
    var row: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var cells = std.mem.splitScalar(u8, std.mem.trim(u8, std.mem.trim(u8, line, " "), "|"), '|');
        var peek = cells;
        var rule = true;
        while (peek.next()) |c| if (!isRule(c)) {
            rule = false;
        };
        if (rule) continue;
        var k: usize = 0;
        while (cells.next()) |c0| : (k += 1) {
            if (k == ncols) break;
            const c = std.mem.trim(u8, c0, " ");
            if (row == 0) {
                head[k] = c;
                continue;
            }
            if (k == 0) {
                put("\x1b[1m");
                plainCell(c);
                put(reset());
                put("\n");
            } else {
                put("  ");
                put(muted());
                plainCell(head[k]);
                put(":");
                put(reset());
                put(" ");
                plainCell(c);
                put("\n");
            }
        }
        row += 1;
    }
}

fn plainCell(c: []const u8) void {
    for (c) |b| if (b != '`' and b != '*') put(&[_]u8{b});
}

fn rawTable(text: []const u8) void {
    put(std.mem.trimEnd(u8, text, "\n"));
    put("\n");
}

fn md(c: u8) void {
    if (tline) { // collecting a table row
        tbl.byte(c);
        if (c == '\n') {
            tline = false;
            lead = true;
            bol = true;
        }
        return;
    }
    if (lead and pend_n == 0 and tbl.len > 0 and c != '|' and c != ' ') flushTable(); // the table ended
    if (c == '\n') {
        const hp = std.mem.trimStart(u8, pend[0..pend_n], " ");
        if (lead and hp.len >= 3 and (hp[0] == '-' or hp[0] == '*' or hp[0] == '_') and std.mem.allEqual(u8, hp, hp[0])) {
            pend_n = 0; // a rule: ---, ***, ___
            put(muted());
            for (0..@min(@as(usize, sys.termCols()) -| 1, 60)) |_| put("─");
            put(reset());
        } else if (lead) flushPend();
        endLine();
        put("\n");
        bol = true;
        lead = true;
        return;
    }
    bol = false;
    if (!lead) return inline_(c);
    pend[pend_n] = c;
    pend_n += 1;
    const p = pend[0..pend_n];
    const indent = p[0 .. p.len - std.mem.trimStart(u8, p, " ").len];
    const r = classify(p, fence);
    switch (r) {
        .wait => if (pend_n < pend.len) return,
        .heading => {
            put(indent);
            put(sgr(&th.accent));
            put("\x1b[1m");
            heading = true;
        },
        .bullet => {
            put(indent);
            put(muted());
            put("•");
            put(reset());
            put(" ");
            const rest = std.mem.trimStart(u8, p, " ")[2..]; // characters held past "- "
            lead = false;
            pend_n = 0;
            for (rest) |b| inline_(b);
            return;
        },
        .done, .todo => {
            put(indent);
            put(if (r == .done) sgr(&th.green) else muted());
            put(if (r == .done) "✓" else "○");
            put(reset());
            put(" ");
        },
        .table => {
            tbl.add(p);
            tline = true;
            lead = false;
            pend_n = 0;
            return;
        },
        .quote => {
            put(indent);
            put(muted());
            put("│");
            put(reset());
            put(" ");
        },
        .fence => { // no ``` on screen: the language (if any) in muted text, then the code indented and green
            fence = !fence;
            put(indent);
            put(if (fence) muted() else reset());
        },
        .text => {
            if (fence) {
                put("  ");
                put(sgr(&th.green));
            }
            lead = false;
            flushPend();
            return;
        },
    }
    if (lead and pend_n == pend.len and classify(p, fence) == .wait) {
        lead = false;
        flushPend();
        return;
    }
    lead = false;
    pend_n = 0;
}

fn flushPend() void {
    const n = pend_n;
    pend_n = 0;
    lead = false;
    for (pend[0..n]) |b| inline_(b);
}

// [text](url): held until it is known; printed as an OSC 8 hyperlink (clickable in kitty, foot, ghostty,
// alacritty; other terminals show the underlined text). Anything else that started with '[' prints as typed.
var link: [400]u8 = undefined;
var link_n: usize = 0;
var link_mid: usize = 0; // index of "](" in link, 0 while still in the text part

fn linkChar(c: u8) bool {
    if (link_n == link.len or c == '\n') return false;
    link[link_n] = c;
    link_n += 1;
    const l = link[0..link_n];
    if (link_mid == 0) {
        if (c == ']') return true;
        if (l.len >= 2 and l[l.len - 2] == ']') {
            if (c != '(') {
                link_n -= 1; // not part of it: the caller prints it after the held text
                return false;
            }
            link_mid = l.len - 2;
        }
        return true;
    }
    if (c != ')') {
        if (c != ' ') return true;
        link_n -= 1;
        return false;
    }
    const text = l[1..link_mid];
    const url = l[link_mid + 2 .. l.len - 1];
    link_n = 0;
    link_mid = 0;
    if (text.len == 0 or url.len == 0) {
        put(l);
        return true;
    }
    put("\x1b]8;;");
    put(url);
    put("\x1b\\\x1b[4m");
    put(text);
    put("\x1b[24m\x1b]8;;\x1b\\");
    return true;
}

fn flushLink() void {
    const n = link_n;
    link_n = 0;
    link_mid = 0;
    put(link[0..n]);
}

fn inline_(c: u8) void {
    if (link_n > 0) {
        if (linkChar(c)) return;
        flushLink();
        if (c == '\n') return;
    }
    if (c == '[' and !fence and !code) {
        link[0] = c;
        link_n = 1;
        return;
    }
    if (fence) return put(&[_]u8{c});
    if (c == '`') {
        if (star) {
            star = false;
            put("*");
        }
        code = !code;
        if (code) put(sgr(&th.green)) else restyle();
        return;
    }
    if (code) return put(&[_]u8{c});
    if (c == '*') {
        if (star) {
            star = false;
            bold = !bold;
            put(if (bold) "\x1b[1m" else "\x1b[22m");
            if (!bold and heading) put("\x1b[1m");
        } else star = true;
        return;
    }
    if (star) {
        star = false;
        put("*");
    }
    put(&[_]u8{c});
}

/// Back to the style the line had before inline code.
fn restyle() void {
    put(reset());
    if (heading) {
        put(sgr(&th.accent));
        put("\x1b[1m");
    } else if (bold) put("\x1b[1m");
}

fn endLine() void {
    if (link_n > 0) flushLink();
    if (fence) put(reset());
    if (star) put("*");
    star = false;
    if (heading or bold or code) put(reset());
    heading = false;
    bold = false;
    code = false;
}

/// A tool call is streaming in: its name and the argument bytes so far, shown on the live line
/// ("⋯ 12s · write 14 KB") so a long write is visibly progressing, not a frozen timer.
pub fn forming(name: []const u8, bytes: usize) void {
    if (!color or oneshot) return;
    if (thinking) endThinking();
    const n = @min(name.len, form_name.len);
    @memcpy(form_name[0..n], name[0..n]);
    form_n = n;
    form_bytes = bytes;
    if (screen.on) return requestDraw();
    const now = sys.nowNs();
    if (now -| last_live < 100 * std.time.ns_per_ms) return;
    last_live = now;
    if (!bol) put("\n");
    bol = true;
    flush();
    drawLive();
}
var form_name: [32]u8 = undefined;
var form_n: usize = 0;
var form_bytes: usize = 0;

fn formingLabel(b: []u8) []const u8 {
    if (form_n == 0) return b[0..0];
    const kb = (form_bytes + 512) / 1024;
    return (if (kb > 0) std.fmt.bufPrint(b, " · {s} {d} KB", .{ form_name[0..form_n], kb }) else std.fmt.bufPrint(b, " · {s}", .{form_name[0..form_n]})) catch b[0..0];
}

/// End of an assistant message: close any open line and color.
pub fn endMessage() void {
    started = false;
    form_n = 0;
    endThinking();
    if (tline) {
        tbl.byte('\n');
        tline = false;
    }
    flushTable();
    if (lead and pend_n > 0) flushPend();
    endLine();
    lead = true;
    if (fence) {
        fence = false;
        put(reset());
    }
    if (!bol) {
        if (oneshot) {
            if (!quiet) sys.writeAll(sys.stdout, "\n") catch {};
        } else put("\n");
        bol = true;
    }
    flush();
}

var tool_name: [16]u8 = undefined;
var tool_name_n: usize = 0;

pub fn tool(name: []const u8, summary: []const u8) void {
    endMessage();
    tool_name_n = @min(name.len, tool_name.len);
    @memcpy(tool_name[0..tool_name_n], name[0..tool_name_n]);
    const w = @as(usize, sys.termCols()) -| (name.len + 4);
    const sm = cut(summary, w);
    print("{s}▸ {s}{s} {s}{s}\n", .{ accent(), name, reset(), sm, if (sm.len < summary.len) "…" else "" });
    flush();
    diff_lines = 0;
    diffed = false;
    liveStart();
}

// Edit diffs: the changed lines of each old/new pair, unchanged lines at both ends
// dropped, at most `max_diff` lines per tool call.
const max_diff = 12;
var diff_lines: usize = 0;
var diff_hidden: usize = 0;
var diffed = false; // the edit's own "edited ..." output is then not repeated

pub fn diff(old: []const u8, new: []const u8) void {
    if (oneshot) return;
    if (!diffed) diff_hidden = 0;
    diffed = true;
    var ol: [256][]const u8 = undefined;
    var nl: [256][]const u8 = undefined;
    const a = lines(old, &ol);
    const b = lines(new, &nl);
    var pre: usize = 0;
    while (pre < a.len and pre < b.len and std.mem.eql(u8, a[pre], b[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < a.len - pre and suf < b.len - pre and std.mem.eql(u8, a[a.len - 1 - suf], b[b.len - 1 - suf])) suf += 1;
    const w = @as(usize, sys.termCols()) -| 5;
    const x = a[pre .. a.len - suf];
    const y = b[pre .. b.len - suf];
    if (x.len >= lcs.len or y.len >= lcs.len) { // too big to align: old lines, then new
        for (x) |l| diffLine(&th.red, "- ", l, w);
        for (y) |l| diffLine(&th.green, "+ ", l, w);
        return flush();
    }
    // Longest common subsequence: lines kept in the middle are not shown as removed and added again.
    var i = x.len + 1;
    while (i > 0) {
        i -= 1;
        var j = y.len + 1;
        while (j > 0) {
            j -= 1;
            lcs[i][j] = if (i == x.len or j == y.len) 0 else if (std.mem.eql(u8, x[i], y[j])) lcs[i + 1][j + 1] + 1 else @max(lcs[i + 1][j], lcs[i][j + 1]);
        }
    }
    i = 0;
    var j: usize = 0;
    while (i < x.len or j < y.len) {
        if (i < x.len and j < y.len and std.mem.eql(u8, x[i], y[j])) {
            i += 1;
            j += 1;
        } else if (j == y.len or (i < x.len and lcs[i + 1][j] >= lcs[i][j + 1])) {
            diffLine(&th.red, "- ", x[i], w);
            i += 1;
        } else {
            diffLine(&th.green, "+ ", y[j], w);
            j += 1;
        }
    }
    flush();
}
var lcs: [129][129]u8 = undefined;

fn diffLine(st: *const Sgr, mark: []const u8, l: []const u8, w: usize) void {
    if (diff_lines == max_diff) {
        diff_hidden += 1;
        return;
    }
    diff_lines += 1;
    put("  ");
    put(sgr(st));
    put(mark);
    const t = cut(l, w);
    put(t);
    if (t.len < l.len) put("…");
    put(reset());
    put("\n");
}

fn lines(s: []const u8, out: [][]const u8) []const []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s, "\n"), '\n');
    while (it.next()) |l| {
        if (n == out.len) break;
        out[n] = std.mem.trimEnd(u8, l, "\r");
        n += 1;
    }
    return out[0..n];
}

/// Show at most 8 lines of tool output, dimmed.
pub fn toolOutput(text: []const u8, ok: bool) void {
    if (oneshot) return;
    if (ok and std.mem.startsWith(u8, text, @import("tools.zig").todo_marker)) {
        setPlan(text);
        last_tool.reset();
        last_tool.add(text);
        return checklist();
    }
    last_tool.reset();
    last_tool.add(text);
    if (ok and diffed) {
        diffed = false;
        if (diff_hidden > 0) print("{s}  … {d} more changed lines{s}\n", .{ muted(), diff_hidden, reset() });
        flush();
        return;
    }
    // What is worth seeing differs by tool: a file the model reads is its business (one line: how much),
    // a command's verdict is at the end (the last lines), a search's best hits are at the top.
    const body = std.mem.trimEnd(u8, text, "\n");
    const total = if (body.len == 0) 0 else std.mem.count(u8, body, "\n") + 1;
    const name = tool_name[0..tool_name_n];
    const w = @as(usize, sys.termCols()) -| 4;
    put(if (ok) muted() else sgr(&th.red));
    defer {
        put(reset());
        flush();
    }
    if (ok and std.mem.eql(u8, name, "read")) {
        const mark = std.mem.lastIndexOf(u8, body, "\n[lines ");
        if (mark) |i| print("  {s}\n", .{cut(body[i + 1 ..], w)}) else print("  {d} line{s}\n", .{ total, if (total == 1) "" else "s" });
        return;
    }
    const keep = 8;
    const at_end = std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "!");
    if (at_end and total > keep) print("  … {d} lines above\n", .{total - keep});
    var it = std.mem.splitScalar(u8, body, '\n');
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        if (if (at_end) i + keep < total else i >= keep) continue;
        put("  ");
        put(cut(l, w));
        put("\n");
    }
    if (!at_end and total > keep) print("  … {d} more lines\n", .{total - keep});
}

fn cut(s: []const u8, w: usize) []const u8 {
    if (s.len <= w) return s;
    var n = w;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// The end-of-turn line: model, time, steps, files changed, context use, awl's memory.
/// Items drop from the end until it fits `w` columns; the model and time always stay.
fn statusLine(out: []u8, model: []const u8, secs: f64, steps: usize, changed: usize, ctx: u64, limit: u64, kb: u64, w: usize) []const u8 {
    var ib: [4][48]u8 = undefined;
    var lb: [16]u8 = undefined;
    const lim = if (limit > 0) (std.fmt.bufPrint(&lb, "/{d}k", .{limit / 1000}) catch "") else "";
    const items = [_][]const u8{
        std.fmt.bufPrint(&ib[0], " · {d} step{s}", .{ steps, if (steps == 1) "" else "s" }) catch "",
        if (changed > 0) (std.fmt.bufPrint(&ib[1], " · {d} file{s} changed", .{ changed, if (changed == 1) "" else "s" }) catch "") else "",
        std.fmt.bufPrint(&ib[2], " · ctx {d:.1}k{s}", .{ @as(f64, @floatFromInt(ctx)) / 1000, lim }) catch "",
        std.fmt.bufPrint(&ib[3], " · {d} KB", .{kb}) catch "",
    };
    var n = (std.fmt.bufPrint(out, "── {s} · {d:.1}s", .{ cut(model, @min(out.len / 2, 64)), secs }) catch return "").len;
    var cols = std.unicode.utf8CountCodepoints(out[0..n]) catch n;
    for (items) |it| {
        const c = std.unicode.utf8CountCodepoints(it) catch it.len;
        if (cols + c > w or n + it.len > out.len) break;
        @memcpy(out[n .. n + it.len], it);
        n += it.len;
        cols += c;
    }
    return out[0..n];
}

pub fn status(model: []const u8, secs: f64, steps: usize, changed: usize, ctx: u64, limit: u64) void {
    if (oneshot) return;
    endMessage();
    var b: [512]u8 = undefined;
    print("{s}{s}{s}\n", .{ muted(), statusLine(&b, model, secs, steps, changed, ctx, limit, sys.rssKb(), @as(usize, sys.termCols()) -| 1), reset() });
    flush();
}

test "end-of-turn line: items drop from the end to fit" {
    var b: [512]u8 = undefined;
    try tt.expectEqualStrings("── m · 3.0s · 7 steps · 1 file changed · ctx 0.1k/32k · 448 KB", statusLine(&b, "m", 3.0, 7, 1, 123, 32000, 448, 80));
    try tt.expectEqualStrings("── m · 3.0s · 7 steps · 1 file changed", statusLine(&b, "m", 3.0, 7, 1, 123, 32000, 448, 50));
    try tt.expectEqualStrings("── m · 3.0s · 1 step · ctx 0.1k · 448 KB", statusLine(&b, "m", 3.0, 1, 0, 123, 0, 448, 40));
    try tt.expectEqualStrings("── m · 3.0s", statusLine(&b, "m", 3.0, 7, 1, 123, 32000, 448, 12));
}

pub fn err(comptime f: []const u8, a: anytype) void {
    endMessage();
    put(sgr(&th.red));
    print(f, a);
    put(reset());
    put("\n");
    flushTo(sys.stderr);
}

/// Put `text` on the clipboard through the terminal (OSC 52: kitty, foot, ghostty,
/// alacritty; works over ssh). Nothing to spawn.
pub fn clipboard(text: []const u8) void {
    const enc = std.base64.standard.Encoder;
    var b = @import("buf.zig").Buf.init(enc.calcSize(text.len) + 16);
    defer b.free();
    b.add("\x1b]52;c;");
    _ = enc.encode(b.extend(enc.calcSize(text.len)), text);
    b.add("\x07");
    if (capture) |c| c.add(b.items()) else if (!quiet) sys.writeAll(sys.stdout, b.items()) catch {};
}

/// The last ``` fenced block in `s` (without the fence lines), or null.
pub fn lastCodeBlock(s: []const u8) ?[]const u8 {
    var open: ?usize = null; // start of the block's body
    var found: ?[]const u8 = null;
    var i: usize = 0;
    while (i < s.len) {
        const end = std.mem.indexOfScalarPos(u8, s, i, '\n') orelse s.len;
        const line = std.mem.trimStart(u8, s[i..end], " ");
        if (std.mem.startsWith(u8, line, "```")) {
            if (open) |o| {
                found = s[o..i];
                open = null;
            } else open = @min(end + 1, s.len);
        }
        i = end + 1;
    }
    return found;
}

/// Print the last tool output in full.
pub fn expand() void {
    if (last_tool.len == 0) return note("no tool output yet", .{});
    endMessage();
    put(last_tool.items());
    if (last_tool.items()[last_tool.len - 1] != '\n') put("\n");
    flush();
}

/// The project directory: shown as relative paths in tool lines and notes.
pub var cwd: []const u8 = "";

/// `s` with every "<cwd>/" removed (and a bare "<cwd>" shown as "."), into `out`.
pub fn shorten(s: []const u8, out: []u8) []const u8 {
    if (cwd.len < 2) return s[0..@min(s.len, out.len)];
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < out.len) {
        if (std.mem.startsWith(u8, s[i..], cwd)) {
            const after = i + cwd.len;
            if (after < s.len and s[after] == '/') {
                i = after + 1;
                continue;
            }
            if (after == s.len or s[after] == ' ' or s[after] == '\n' or s[after] == '"' or s[after] == '\'') {
                out[n] = '.';
                n += 1;
                i = after;
                continue;
            }
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// An approval question; the answer replaces it on the same line.
pub fn ask(q: []const u8) void {
    endMessage();
    put(sgr(&th.yellow));
    put(q);
    put(reset());
    flush();
}
pub fn answered(word: []const u8) void {
    put("\r\x1b[K");
    put(muted());
    put("  ");
    put(word);
    put(reset());
    put("\n");
    flush();
}

/// A message the user queued mid-run, shown where the model receives it.
pub fn userEcho(text: []const u8) void {
    endMessage();
    put(accent());
    put("› ");
    put(reset());
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) put("\n  ");
        first = false;
        put(l);
    }
    put("\n");
    flush();
}

/// One line printed as given (it carries its own colors).
pub fn raw(s: []const u8) void {
    endMessage();
    put(s);
    put(reset());
    put("\n");
    flush();
}

pub fn note(comptime f: []const u8, a: anytype) void {
    noteAs(true, f, a);
}

/// `short`: project paths read as relative (not for the banner, which names the project).
pub fn noteAs(short: bool, comptime f: []const u8, a: anytype) void {
    endMessage();
    put(muted());
    print_buf.truncate(0);
    print_buf.print(f, a);
    var sb = @import("buf.zig").Buf.init(print_buf.len + 16);
    defer sb.free();
    put(if (short) shorten(print_buf.items(), sb.extend(print_buf.len)) else print_buf.items());
    put(reset());
    put("\n");
    flush();
}

const tt = std.testing;

fn render(f: anytype, args: anytype) ![]const u8 {
    const Buf = @import("buf.zig").Buf;
    const S = struct {
        var b: Buf = undefined;
    };
    S.b = Buf.init(1 << 16);
    capture = &S.b;
    defer capture = null;
    @call(.auto, f, args);
    flush();
    return S.b.items();
}

fn mdAll(s: []const u8) void {
    // stream it in small pieces, like the model does
    var i: usize = 0;
    while (i < s.len) : (i += 3) content(s[i..@min(i + 3, s.len)]);
    endMessage();
}

test "markdown-lite: headings, bullets, bold, code, fences" {
    color = true;
    defer color = false;
    const got = try render(mdAll, .{"# Title\n- item **bold** and `x`\n```zig\nconst a = 1; // **no**\n```\nplain * star\n#include\n"});
    try tt.expectEqualStrings(
        "\x1b[1mTitle\x1b[0m\n" ++
            "•\x1b[0m item \x1b[1mbold\x1b[22m and x\x1b[0m\n" ++
            "zig\x1b[0m\n  const a = 1; // **no**\x1b[0m\n" ++
            "\x1b[0m\n" ++
            "plain * star\n#include\n",
        got,
    );
}

test "markdown-lite: tables align, quotes get a bar, a table in a fence stays as typed (fences hidden)" {
    color = true;
    defer color = false;
    const got = try render(mdAll, .{"| a | long name |\n|---|:---:|\n| `x` | **y** |\nafter\n> q\n```\n| raw |\n```\n"});
    try tt.expectEqualStrings(
        "  a  long name\n  " ++ "─" ** 12 ++ "\n  x  y\nafter\n│ q\n\n  | raw |\n\n",
        try stripSgr(got),
    );
}

test "markdown-lite: links, rules, task items; brackets that are not links print as typed" {
    color = true;
    defer color = false;
    const got = try render(mdAll, .{"see [docs](https://x.y/z) now\n---\n- [x] done\n- [ ] open\n- plain\n[1] a[i] [a](b c)\n"});
    try tt.expect(std.mem.indexOf(u8, got, "\x1b]8;;https://x.y/z\x1b\\\x1b[4mdocs\x1b[24m\x1b]8;;\x1b\\ now") != null);
    const txt = try stripSgr(got);
    try tt.expect(std.mem.indexOf(u8, txt, "─" ** 20) != null);
    try tt.expect(std.mem.indexOf(u8, txt, "✓ done\n○ open\n• plain\n[1] a[i] [a](b c)\n") != null);
}

test "tool output: read is one line, bash shows its end, search its top" {
    quiet = false;
    const ten = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";
    tool_name_n = 4;
    @memcpy(tool_name[0..4], "read");
    try tt.expectEqualStrings("  10 lines\n", try stripSgr(try render(toolOutput, .{ ten, true })));
    try tt.expectEqualStrings("  [lines 2-3 of 4; use offset=4 to continue]\n", try stripSgr(try render(toolOutput, .{ "2→b\nc\n[lines 2-3 of 4; use offset=4 to continue]", true })));
    tool_name_n = 4;
    @memcpy(tool_name[0..4], "bash");
    try tt.expectEqualStrings("  … 2 lines above\n  3\n  4\n  5\n  6\n  7\n  8\n  9\n  10\n", try stripSgr(try render(toolOutput, .{ ten, true })));
    tool_name_n = 4;
    @memcpy(tool_name[0..4], "grep");
    try tt.expectEqualStrings("  1\n  2\n  3\n  4\n  5\n  6\n  7\n  8\n  … 2 more lines\n", try stripSgr(try render(toolOutput, .{ ten, true })));
}

test "markdown-lite: a wide table wraps its cells to fit; too many columns become records" {
    color = true;
    defer color = false;
    const words = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen";
    const got = try stripSgr(try render(mdAll, .{"| n | note |\n|---|---|\n| a | " ++ words ++ " " ++ words ++ " |\n"}));
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, got, "\n"), '\n');
    var rows: usize = 0;
    while (it.next()) |l| : (rows += 1) try tt.expect(textCols(l) <= 80);
    try tt.expect(rows >= 4 and std.mem.startsWith(u8, got, "  n  note"));
    const many = "| a | b | c | d | e | f | g | h | i |\n|-|-|-|-|-|-|-|-|-|\n| " ++ ("xxxxxxxxxxxx | " ** 8) ++ "x |\n";
    try tt.expect(std.mem.indexOf(u8, try stripSgr(try render(mdAll, .{many})), "  b: xxxxxxxxxxxx\n") != null);
}

var strip_b: [4096]u8 = undefined;
fn stripSgr(s: []const u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == ']') { // OSC ... ESC \
            i += 2;
            while (i + 1 < s.len and !(s[i] == 0x1b and s[i + 1] == '\\')) i += 1;
            i += 1;
            continue;
        }
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            continue;
        }
        if (n == strip_b.len) return error.NoSpaceLeft;
        strip_b[n] = s[i];
        n += 1;
    }
    return strip_b[0..n];
}

test "markdown-lite: unfinished markers print as typed" {
    color = true;
    defer color = false;
    try tt.expectEqualStrings("-\n2 * 3 = 6*\n", try render(mdAll, .{"-\n2 * 3 = 6*\n"}));
}

test "edit diff: lines kept in the middle are not shown" {
    diff_lines = 0;
    try tt.expectEqualStrings("  -     x = 1\n  +     x = 2\n  + n = len(s)\n  + y = n\n", try render(diff, .{ "def f():\n    x = 1\ns = sorted(v)\nreturn s\n", "def f():\n    x = 2\ns = sorted(v)\nn = len(s)\ny = n\nreturn s\n" }));
    diff_lines = 0;
    diffed = false;
}

test "edit diff: only changed lines, capped" {
    try tt.expectEqualStrings("  - b\n  + B\n", try render(diff, .{ "a\nb\nc\n", "a\nB\nc\n" }));
    diff_lines = 0;
    const big = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n";
    _ = try render(diff, .{ big, "x\n" });
    try tt.expectEqual(@as(usize, max_diff), diff_lines);
    try tt.expectEqual(@as(usize, 16 - max_diff), diff_hidden);
    diff_lines = 0;
    diffed = false;
}

test "copy: last code block and OSC 52" {
    try tt.expectEqualStrings("b = 2\n", lastCodeBlock("x\n```py\na = 1\n```\ntext\n```\nb = 2\n```\n").?);
    try tt.expect(lastCodeBlock("no code\n```\nunclosed") == null);
    try tt.expectEqualStrings("\x1b]52;c;aGk=\x07", try render(clipboard, .{"hi"}));
}

test "paths under the project are shown relative" {
    cwd = "/home/u/proj";
    defer cwd = "";
    var b: [128]u8 = undefined;
    try tt.expectEqualStrings("src/a.zig and cd . && ls", shorten("/home/u/proj/src/a.zig and cd /home/u/proj && ls", &b));
    try tt.expectEqualStrings("/home/u/project/x", shorten("/home/u/project/x", &b)); // not a prefix match
}

test "long notes are printed whole" {
    const long = "x" ** 3000;
    try tt.expectEqual(@as(usize, 3001), (try render(note, .{ "{s}", .{long} })).len);
}
