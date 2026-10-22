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

/// Load the active Omarchy theme. Missing file → terminal default colors.
pub fn loadTheme() void {
    const fallback = .{ .{ &th.accent, "\x1b[34m" }, .{ &th.fg, "\x1b[39m" }, .{ &th.muted, "\x1b[90m" }, .{ &th.red, "\x1b[31m" }, .{ &th.green, "\x1b[32m" }, .{ &th.yellow, "\x1b[33m" } };
    inline for (fallback) |f| {
        @memcpy(f[0].b[0..f[1].len], f[1]);
        f[0].n = f[1].len;
    }
    const home = sys.getenv("HOME") orelse return;
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/.local/state/omarchy/current/theme/colors.toml", .{home}) catch return;
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
pub fn plain() []const u8 {
    return reset();
}

// Output is staged in a small buffer and flushed once per call.
var ob: [8192]u8 = undefined;
var on: usize = 0;
pub var capture: ?*@import("buf.zig").Buf = null; // tests: collect output here instead
fn put(s: []const u8) void {
    if (live) { // a live status line is on screen: clear it before real output
        live = false;
        put("\r\x1b[K");
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
    if (capture) |c| c.add(ob[0..on]) else if (!quiet) sys.writeAll(fd, ob[0..on]) catch {};
    on = 0;
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
var tail: [256]u8 = undefined;
var tail_n: usize = 0;

pub fn reasoning(s: []const u8) void {
    if (!color or oneshot) return;
    if (!thinking) {
        thinking = true;
        think_start = sys.nowNs();
        tail_n = 0;
    }
    for (s) |c0| {
        const c = if (c0 == '\n' or c0 == '\t') ' ' else c0;
        if (tail_n == tail.len) {
            std.mem.copyForwards(u8, tail[0 .. tail.len - 64], tail[64..]);
            tail_n -= 64;
        }
        tail[tail_n] = c;
        tail_n += 1;
    }
    if (draft.len > 0 or queued > 0 or held.len > 0) return drawLive();
    const w = @min(@as(usize, sys.termCols()) -| 6, tail_n);
    var start = tail_n - w;
    while (start < tail_n and (tail[start] & 0xC0) == 0x80) start += 1; // utf-8 boundary
    put("\r\x1b[K");
    put(muted());
    put("∴ ");
    put(tail[start..tail_n]);
    put(reset());
    flush();
}

// Live line: while the model or a tool works and nothing else is printing, one dim
// line shows the elapsed time and whatever the user is typing (sent at the next step).
var live = false;
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
    if (thinking) {
        if (draft.len > 0 or queued > 0 or held.len > 0) drawLive();
        return;
    }
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
    var b: [1024]u8 = undefined;
    var n: usize = 0;
    const secs = (sys.nowNs() - live_t0) / std.time.ns_per_s;
    const w = @as(usize, sys.termCols()) -| 1;
    const head = std.fmt.bufPrint(&b, "\r\x1b[K{s}{s} {d}s", .{ muted(), if (thinking) "∴" else "⋯", secs }) catch return;
    n = head.len;
    var cols: usize = 4 + std.fmt.count("{d}", .{secs});
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
    sys.writeAll(sys.stdout, b[0..n]) catch {};
    live = true;
}

fn endThinking() void {
    if (!thinking) return;
    thinking = false;
    const secs = @as(f64, @floatFromInt(sys.nowNs() - think_start)) / 1e9;
    put("\r\x1b[K");
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

const Lead = enum { wait, heading, bullet, fence, text };

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
        return if (s.len == 2 and s[1] == ' ') .bullet else .text;
    }
    return .text;
}

fn md(c: u8) void {
    if (c == '\n') {
        if (lead) flushPend();
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
    switch (classify(p, fence)) {
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
        },
        .fence => {
            fence = !fence;
            put(indent);
            put(sgr(&th.green));
            put("```");
            if (!fence) put(reset());
        },
        .text => {
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

fn inline_(c: u8) void {
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
    if (star) put("*");
    star = false;
    if (heading or bold or code) put(reset());
    heading = false;
    bold = false;
    code = false;
}

/// End of an assistant message: close any open line and color.
pub fn endMessage() void {
    started = false;
    endThinking();
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

pub fn tool(name: []const u8, summary: []const u8) void {
    endMessage();
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
    for (a[pre .. a.len - suf]) |l| diffLine(&th.red, "- ", l, w);
    for (b[pre .. b.len - suf]) |l| diffLine(&th.green, "+ ", l, w);
    flush();
}

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
    last_tool.reset();
    last_tool.add(text);
    if (ok and diffed) {
        diffed = false;
        if (diff_hidden > 0) print("{s}  … {d} more changed lines{s}\n", .{ muted(), diff_hidden, reset() });
        flush();
        return;
    }
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var shown: usize = 0;
    var total: usize = 0;
    const w = @as(usize, sys.termCols()) -| 4;
    put(if (ok) muted() else sgr(&th.red));
    while (it.next()) |l| : (total += 1) {
        if (shown == 8) continue;
        put("  ");
        put(cut(l, w));
        put("\n");
        shown += 1;
    }
    if (total > shown) print("  … {d} more lines\n", .{total - shown});
    put(reset());
    flush();
}

fn cut(s: []const u8, w: usize) []const u8 {
    if (s.len <= w) return s;
    var n = w;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// End of a turn: model, time, steps, files changed, context use, awl's memory.
pub fn status(model: []const u8, secs: f64, steps: usize, changed: usize, ctx: u64, limit: u64) void {
    if (oneshot) return;
    endMessage();
    var lb: [32]u8 = undefined;
    const lim = if (limit > 0) (std.fmt.bufPrint(&lb, "/{d}k", .{limit / 1000}) catch "") else "";
    var cb: [32]u8 = undefined;
    const ch = if (changed > 0) (std.fmt.bufPrint(&cb, " · {d} file{s} changed", .{ changed, if (changed == 1) "" else "s" }) catch "") else "";
    print("{s}── {s} · {d:.1}s · {d} step{s}{s} · ctx {d:.1}k{s} · {d} KB{s}\n", .{ muted(), model, secs, steps, if (steps == 1) "" else "s", ch, @as(f64, @floatFromInt(ctx)) / 1000, lim, sys.rssKb(), reset() });
    flush();
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
            "```zig\nconst a = 1; // **no**\n" ++
            "```\x1b[0m\n" ++
            "plain * star\n#include\n",
        got,
    );
}

test "markdown-lite: unfinished markers print as typed" {
    color = true;
    defer color = false;
    try tt.expectEqualStrings("-\n2 * 3 = 6*\n", try render(mdAll, .{"-\n2 * 3 = 6*\n"}));
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
