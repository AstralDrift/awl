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
fn put(s: []const u8) void {
    if (s.len > ob.len - on) flushTo(if (oneshot) sys.stderr else sys.stdout);
    if (s.len > ob.len) {
        sys.writeAll(if (oneshot) sys.stderr else sys.stdout, s) catch {};
        return;
    }
    @memcpy(ob[on .. on + s.len], s);
    on += s.len;
}
fn flushTo(fd: sys.fd_t) void {
    if (!quiet) sys.writeAll(fd, ob[0..on]) catch {};
    on = 0;
}
fn flush() void {
    flushTo(if (oneshot) sys.stderr else sys.stdout);
}
fn print(comptime f: []const u8, a: anytype) void {
    var t: [1024]u8 = undefined;
    put(std.fmt.bufPrint(&t, f, a) catch t[0..0]);
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

fn endThinking() void {
    if (!thinking) return;
    thinking = false;
    const secs = @as(f64, @floatFromInt(sys.nowNs() - think_start)) / 1e9;
    put("\r\x1b[K");
    print("{s}∴ thought {d:.1}s{s}\n", .{ muted(), secs, reset() });
}

var started = false; // has this message printed any text yet

pub fn content(s0: []const u8) void {
    // Models often open with blank lines; drop them so replies start flush.
    const s = if (started) s0 else std.mem.trimStart(u8, s0, " \t\r\n");
    if (s.len == 0) return;
    started = true;
    endThinking();
    if (oneshot) {
        if (!quiet) sys.writeAll(sys.stdout, s) catch {};
        bol = s[s.len - 1] == '\n';
        return;
    }
    for (s) |c| {
        if (c == '\n') {
            bol = true;
            ticks = 0;
        } else if (bol and c == '`') {
            ticks += 1;
            if (ticks == 3) {
                fence = !fence;
                put(if (fence) sgr(&th.green) else reset());
            }
        } else {
            bol = false;
            ticks = 0;
        }
        put(&[_]u8{c});
    }
    flush();
}

/// End of an assistant message: close any open line and color.
pub fn endMessage() void {
    started = false;
    endThinking();
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
}

/// Show at most 8 lines of tool output, dimmed.
pub fn toolOutput(text: []const u8, ok: bool) void {
    if (oneshot) return;
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

pub fn status(model: []const u8, tok: u64, secs: f64, ctx: u64, limit: u64) void {
    if (oneshot) return;
    endMessage();
    const tps = if (secs > 0) @as(f64, @floatFromInt(tok)) / secs else 0;
    var lb: [32]u8 = undefined;
    const lim = if (limit > 0) (std.fmt.bufPrint(&lb, "/{d}k", .{limit / 1000}) catch "") else "";
    print("{s}── {s} · {d:.1} tok/s · ctx {d:.1}k{s} · {d} KB{s}\n", .{ muted(), model, tps, @as(f64, @floatFromInt(ctx)) / 1000, lim, sys.rssKb(), reset() });
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

pub fn note(comptime f: []const u8, a: anytype) void {
    endMessage();
    put(muted());
    print(f, a);
    put(reset());
    put("\n");
    flush();
}
