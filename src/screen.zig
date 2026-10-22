//! Full-screen mode (awl --full, /full): the alternate screen holds the conversation in
//! a view that scrolls (PgUp/PgDn, mouse wheel), with the live area, the input and the
//! status line pinned at the bottom. ui's output stream (text, SGR colors, "\n", and
//! "\r\x1b[K" line rewrites) is kept as a transcript of lines and drawn from there.
//! Leaving the mode prints the transcript to the normal screen, so nothing is lost.
const std = @import("std");
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;

pub var on = false;

var text = Buf.init(1 << 30); // the transcript: lines separated by '\n', SGR codes kept
var starts = Buf.init(64 << 20); // u32 offset of each line's start
var esc: enum { none, esc, csi, osc } = .none;
var seq: [32]u8 = undefined;
var seq_n: usize = 0;
var cr = false; // a bare '\r': what follows rewrites the line

pub var scroll: usize = 0; // rows the view is moved up from the bottom
var unseen: usize = 0; // lines added while scrolled up

fn lineCount() usize {
    return starts.len / 4;
}

fn lineStart(i: usize) usize {
    return std.mem.readInt(u32, starts.items()[i * 4 ..][0..4], .little);
}

fn line(i: usize) []const u8 {
    const a = lineStart(i);
    const b = if (i + 1 < lineCount()) lineStart(i + 1) - 1 else text.len;
    return text.items()[a..b];
}

fn newLine() void {
    if (lineCount() > 0) text.byte('\n');
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @intCast(text.len), .little);
    starts.add(&b);
    if (scroll > 0) { // scrolled up: keep the view where it is
        scroll += 1;
        unseen += 1;
    }
}

/// Empty the current line (a "\r\x1b[K" rewrite).
fn clearLine() void {
    text.truncate(lineStart(lineCount() - 1));
}

pub fn feed(s: []const u8) void {
    if (lineCount() == 0) newLine();
    for (s) |c| switch (esc) {
        .none => switch (c) {
            27 => {
                esc = .esc;
                seq_n = 0;
            },
            '\n' => {
                cr = false;
                newLine();
            },
            '\r' => cr = true,
            else => {
                if (cr) clearLine();
                cr = false;
                text.byte(if (c == '\t') ' ' else c);
            },
        },
        .esc => esc = switch (c) {
            '[' => .csi,
            ']' => .osc,
            else => .none, // includes the '\\' that ends an OSC

        },
        .csi => {
            if (seq_n < seq.len) seq[seq_n] = c;
            seq_n += 1;
            if (c < 0x40 or c > 0x7e) continue;
            esc = .none;
            switch (c) {
                'm' => { // color: kept
                    if (cr) clearLine();
                    cr = false;
                    text.add("\x1b[");
                    text.add(seq[0..@min(seq_n, seq.len)]);
                },
                'K', 'J' => if (cr) {
                    clearLine();
                    cr = false;
                },
                else => {}, // cursor moves belong to the inline layout
            }
        },
        .osc => if (c == 7) { // ends with BEL, or ESC \\ (handled as .esc)
            esc = .none;
        } else if (c == 27) {
            esc = .esc;
        },
    };
}

/// Forget everything (leaving the mode).
pub fn reset() void {
    text.reset();
    starts.reset();
    scroll = 0;
    unseen = 0;
    cr = false;
    esc = .none;
}

/// The whole transcript, for printing on the normal screen.
pub fn all() []const u8 {
    return text.items();
}

pub fn scrollBy(rows: isize) void {
    if (rows < 0) {
        scroll -|= @intCast(-rows);
    } else scroll += @intCast(rows);
    if (scroll == 0) unseen = 0;
}

/// One screen row of a line: bytes [a, b) and the last color set before a.
const Row = struct { a: usize, b: usize, sgr: []const u8 };

/// Split `l` into rows of at most `w` columns. Escape sequences take no room; a UTF-8
/// sequence takes one column.
fn wrap(l: []const u8, w: usize, out: []Row) []Row {
    var n: usize = 0;
    var a: usize = 0;
    var cols: usize = 0;
    var sgr: []const u8 = "";
    var row_sgr: []const u8 = "";
    var i: usize = 0;
    while (i < l.len) {
        if (l[i] == 27) { // CSI ... m
            var j = i + 2;
            while (j < l.len and (l[j] < 0x40 or l[j] > 0x7e)) j += 1;
            j = @min(j + 1, l.len);
            sgr = l[i..j];
            i = j;
            continue;
        }
        const k = @min(std.unicode.utf8ByteSequenceLength(l[i]) catch 1, l.len - i);
        if (cols == w) {
            if (n == out.len) return out[0..n];
            out[n] = .{ .a = a, .b = i, .sgr = row_sgr };
            n += 1;
            a = i;
            row_sgr = sgr;
            cols = 0;
        }
        i += k;
        cols += 1;
    }
    if (n < out.len) {
        out[n] = .{ .a = a, .b = l.len, .sgr = row_sgr };
        n += 1;
    }
    return out[0..n];
}

const Slot = struct { l: usize, r: Row };

/// The rows the view shows, bottom first (at most `view`). A scroll past the top is
/// pulled back so the first page shows.
fn collect(view: usize, w: usize, rows: []Slot) usize {
    const room = @min(view, rows.len);
    var got: usize = 0; // rows passed so far, from the bottom
    var skip = scroll;
    var fill: usize = 0;
    var li = lineCount();
    if (li > 0 and line(li - 1).len == 0) li -= 1; // the line being written is still empty
    var wr: [256]Row = undefined;
    while (li > 0 and fill < room) {
        li -= 1;
        const rs = wrap(line(li), w, &wr);
        var k = rs.len;
        while (k > 0 and fill < room) {
            k -= 1;
            got += 1;
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            rows[fill] = .{ .l = li, .r = rs[k] };
            fill += 1;
        }
    }
    if (fill < room and scroll > 0) { // ran out of rows above: show the top page
        const top = got -| room;
        if (top < scroll) {
            scroll = top;
            if (scroll == 0) unseen = 0;
            return collect(view, w, rows);
        }
    }
    return fill;
}

/// Draw the screen: the transcript in the top rows, then `bottom` (rows already cut to
/// the width, each with its own colors) at the foot. The cursor goes to `cursor`
/// (row within `bottom`, column), or is hidden.
pub fn draw(bottom: []const []const u8, cursor: ?[2]usize) void {
    const h: usize = sys.termRows();
    const w: usize = sys.termCols();
    const foot = @min(bottom.len, h -| 1);
    const view = h - foot;
    var b = Buf.init(1 << 20);
    defer b.free();
    b.add("\x1b[?2026h\x1b[?25l"); // draw in one frame; cursor hidden while drawing
    var rows: [512]Slot = undefined;
    const fill = collect(view, w, &rows);
    // fill the view top-down: blank rows first when the transcript is short
    var r: usize = 0;
    while (r < view) : (r += 1) {
        b.print("\x1b[{d};1H\x1b[0m", .{r + 1});
        const from_top = view - 1 - r;
        if (from_top < fill) {
            const x = rows[from_top];
            b.add(x.r.sgr);
            b.add(line(x.l)[x.r.a..x.r.b]);
        }
        b.add("\x1b[0m\x1b[K");
    }
    if (scroll > 0 and view > 0) { // where we are, top right
        var tb: [64]u8 = undefined;
        const t = if (unseen > 0) std.fmt.bufPrint(&tb, " ↓ {d} new · PgDn ", .{unseen}) catch "" else std.fmt.bufPrint(&tb, " ↑ {d} rows · PgDn ", .{scroll}) catch "";
        const tw = std.unicode.utf8CountCodepoints(t) catch t.len;
        b.print("\x1b[1;{d}H\x1b[7m{s}\x1b[0m", .{ (w -| tw) + 1, t });
    }
    for (bottom[bottom.len - foot ..], 0..) |row, k| {
        b.print("\x1b[{d};1H\x1b[0m{s}\x1b[0m\x1b[K", .{ view + k + 1, row });
    }
    if (cursor) |c| {
        const cr_row = c[0] -| (bottom.len - foot);
        b.print("\x1b[{d};{d}H\x1b[?25h", .{ view + cr_row + 1, c[1] + 1 });
    }
    b.add("\x1b[?2026l");
    sys.writeAll(sys.stdout, b.items()) catch {};
}

const tt = std.testing;

test "transcript: lines, colors kept, \\r\\x1b[K rewrites a line, cursor moves dropped" {
    reset();
    feed("one\n\x1b[90mtwo\x1b[0m\nthinking…");
    feed("\r\x1b[K∴ thought 1.0s\n\x1b[2A\r\x1b[Jdone");
    try tt.expectEqual(@as(usize, 4), lineCount());
    try tt.expectEqualStrings("one", line(0));
    try tt.expectEqualStrings("\x1b[90mtwo\x1b[0m", line(1));
    try tt.expectEqualStrings("∴ thought 1.0s", line(2));
    try tt.expectEqualStrings("done", line(3));
    reset();
}

test "wrap: escape sequences take no room, colors carry to the next row" {
    var wr: [8]Row = undefined;
    const l = "\x1b[32mabcdef\x1b[0mgh";
    const rs = wrap(l, 4, &wr);
    try tt.expectEqual(@as(usize, 2), rs.len);
    try tt.expectEqualStrings("\x1b[32mabcd", l[rs[0].a..rs[0].b]);
    try tt.expectEqualStrings("ef\x1b[0mgh", l[rs[1].a..rs[1].b]);
    try tt.expectEqualStrings("\x1b[32m", rs[1].sgr);
    try tt.expectEqual(@as(usize, 1), wrap("", 4, &wr).len);
}

test "scrolling past the top shows the first page, not a blank view" {
    reset();
    feed("l0\nl1\nl2\nl3\nl4\n");
    var rows: [8]Slot = undefined;
    scroll = 100;
    try tt.expectEqual(@as(usize, 3), collect(3, 80, &rows));
    try tt.expectEqual(@as(usize, 2), scroll);
    try tt.expectEqualStrings("l0", line(rows[2].l));
    // a short transcript has no page above
    scroll = 5;
    try tt.expectEqual(@as(usize, 5), collect(10, 80, &rows));
    try tt.expectEqual(@as(usize, 0), scroll);
    reset();
}

test "new lines while scrolled up keep the view; OSC ended by ESC backslash" {
    reset();
    feed("a\nb\nc\n");
    scroll = 1;
    feed("d\n");
    try tt.expectEqual(@as(usize, 2), scroll);
    feed("x\x1b]0;title\x1b\\y\n");
    try tt.expectEqualStrings("xy", line(lineCount() - 2));
    reset();
}
