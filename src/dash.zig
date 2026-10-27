//! The ← view: agents and sessions, full screen and live. Background agents report through
//! their status files (agents.zig), so the list and the preview move as they work. From
//! here: open a session at the prompt, start a background agent, message one, answer its
//! questions, stop it, rename, fork or delete a session.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const ui = @import("ui.zig");
const agents = @import("agents.zig");
const session = @import("session.zig");
const tools = @import("tools.zig");
const screen = @import("screen.zig");
const Buf = @import("buf.zig").Buf;
const Row = agents.Row;

pub const Key = union(enum) { none, eof, char: u8, ctrl: u8, up, down, left, right, enter, esc, back, del, tab, pgup, pgdn, home, end, paste_start, paste_end };
pub const Action = union(enum) { close, open: []const u8 };
/// Reads the next key, or .none after `ms` with no input.
pub const Next = *const fn (ms: i32) Key;

const max_rows = 400;
var rows_mem = Buf.init(max_rows * @sizeOf(Row));
var rows: []Row = &.{};
const Line = struct { row: u16 = 0, header: u8 = 0 }; // header 0: a session; 1-3: a section title
var lines: [max_rows + 3]Line = undefined;
var n_lines: usize = 0;
var sel: usize = 0; // index into lines; always a session line when there is one
var sel_name_b: [72]u8 = undefined;
var sel_name_n: usize = 0;
var top: usize = 0; // first list line shown
var all_folders = false;
var filter_b: [128]u8 = undefined;
var filter_n: usize = 0;
const Mode = enum { list, search, new_agent, message, rename, confirm_delete };
var mode: Mode = .list;
var line_b: [8192]u8 = undefined; // the input line
var line_n: usize = 0;
var pasting = false;
var flash_b: [300]u8 = undefined;
var flash_n: usize = 0;
var flash_bad = false;
var zoom = false; // the preview takes the whole screen
var scroll: usize = 0; // preview lines scrolled up from the end (zoom)
var frame = Buf.init(1 << 20);
var last_frame = Buf.init(1 << 20);
var pending_b: [48]u8 = undefined; // a just-started agent's prompt: select it when it shows up
var pending_n: usize = 0;
var pending_until: u64 = 0;
var open_b: [600]u8 = undefined;
var this_name: []const u8 = "";

fn out(s: []const u8) void {
    sys.writeAll(sys.stdout, s) catch {};
}

fn flash(bad: bool, comptime f: []const u8, a: anytype) void {
    flash_n = if (std.fmt.bufPrint(&flash_b, f, a)) |x| x.len else |_| 0;
    flash_bad = bad;
}

pub fn run(next: Next) Action {
    this_name = std.fs.path.basename(session.path);
    if (!screen.on) out("\x1b[?1049h");
    out("\x1b[?25l\x1b[H\x1b[2J");
    defer {
        out("\x1b[0m\x1b[H\x1b[2J\x1b[?25h");
        if (!screen.on) out("\x1b[?1049l");
        rows_mem.free();
        frame.free();
        last_frame.free();
        pv.free();
    }
    mode = .list;
    zoom = false;
    scroll = 0;
    flash_n = 0;
    pv_name_n = 0;
    last_frame.reset();
    @memcpy(sel_name_b[0..this_name.len], this_name);
    sel_name_n = this_name.len;
    rescan();
    if (n_lines > 1 and lines[0].header == 1) { // something needs an answer: start there
        sel = 1;
        remember();
    }
    var last_scan = sys.nowNs();
    var last_live = last_scan;
    while (true) {
        draw();
        const k = next(if (spinning()) 100 else 400);
        switch (k) {
            .none => {},
            .eof => return .close,
            else => if (key(k)) |a| return a,
        }
        const now = sys.nowNs();
        if (now -| last_live > 250 * std.time.ns_per_ms) {
            last_live = now;
            for (rows) |*r| if (r.has_live) r.refreshLive();
            rebuild();
        }
        const every: u64 = if (pending_n > 0 and now < pending_until) 300 else if (all_folders) 4000 else 2000;
        if (now -| last_scan > every * std.time.ns_per_ms) {
            last_scan = now;
            rescan();
        }
    }
}

// ---- the list ----

fn rescan() void {
    if (rows_mem.len == 0) _ = rows_mem.extend(max_rows * @sizeOf(Row));
    const all = @as([*]Row, @ptrCast(@alignCast(rows_mem.items().ptr)))[0..max_rows];
    rows = agents.scan(if (all_folders) null else session.start_cwd, all);
    if (pending_n > 0) {
        for (rows) |*r| if (std.mem.startsWith(u8, r.title(), pending_b[0..pending_n])) {
            @memcpy(sel_name_b[0..r.name_n], r.name());
            sel_name_n = r.name_n;
            pending_n = 0;
            break;
        };
        if (sys.nowNs() > pending_until) pending_n = 0;
    }
    rebuild();
}

fn isThis(r: *const Row) bool {
    return std.mem.eql(u8, r.name(), this_name);
}

/// 0 needs you, 1 running, 2 the rest.
fn group(r: *const Row) u8 {
    if (!r.has_live or !r.live.alive or isThis(r)) return 2;
    if (r.live.kind == .bg and r.live.state == .waiting) return 0;
    if (r.live.state == .running or r.live.state == .waiting) return 1;
    return 2;
}

fn matches(r: *const Row) bool {
    if (filter_n == 0) return true;
    const q = filter_b[0..filter_n];
    return std.ascii.indexOfIgnoreCase(r.title(), q) != null or std.ascii.indexOfIgnoreCase(r.cwd(), q) != null;
}

/// Group, filter and order the rows into `lines`; keep the selection on the same session.
fn rebuild() void {
    var idx: [max_rows]u16 = undefined;
    var k: usize = 0;
    for (rows, 0..) |*r, i| if (matches(r)) {
        idx[k] = @intCast(i);
        k += 1;
    };
    const C = struct {
        fn lt(_: void, a: u16, b: u16) bool {
            const ra = &rows[a];
            const rb = &rows[b];
            const ga = group(ra);
            const gb = group(rb);
            if (ga != gb) return ga < gb;
            if (isThis(ra) != isThis(rb)) return isThis(ra);
            if (ra.mtime != rb.mtime) return ra.mtime > rb.mtime;
            return a < b;
        }
    };
    std.sort.pdq(u16, idx[0..k], {}, C.lt);
    n_lines = 0;
    var prev: u8 = 255;
    for (idx[0..k]) |i| {
        const g = group(&rows[i]);
        if (g != prev) {
            lines[n_lines] = .{ .header = g + 1 };
            n_lines += 1;
            prev = g;
        }
        lines[n_lines] = .{ .row = i };
        n_lines += 1;
    }
    sel = 0;
    var found = false;
    for (lines[0..n_lines], 0..) |l, i| if (l.header == 0 and std.mem.eql(u8, rows[l.row].name(), sel_name_b[0..sel_name_n])) {
        sel = i;
        found = true;
        break;
    };
    if (!found) {
        while (sel < n_lines and lines[sel].header != 0) sel += 1;
        remember();
    }
}

fn selected() ?*Row {
    if (sel >= n_lines or lines[sel].header != 0) return null;
    return &rows[lines[sel].row];
}

fn remember() void {
    const r = selected() orelse return;
    @memcpy(sel_name_b[0..r.name_n], r.name());
    sel_name_n = r.name_n;
}

/// Move the selection by `d` sessions (section titles are skipped).
fn move(d: isize) void {
    var i: isize = @intCast(sel);
    var left = if (d < 0) -d else d;
    const step: isize = if (d < 0) -1 else 1;
    while (left > 0) {
        var j = i + step;
        while (j >= 0 and j < n_lines and lines[@intCast(j)].header != 0) j += step;
        if (j < 0 or j >= n_lines) break;
        i = j;
        left -= 1;
    }
    sel = @intCast(i);
    scroll = 0;
    remember();
}

fn spinning() bool {
    for (rows) |*r| if (r.has_live and r.live.alive and r.live.state == .running) return true;
    return false;
}

// ---- keys ----

fn key(k: Key) ?Action {
    if (mode != .list) return inputKey(k);
    const r = selected();
    var pb: [600]u8 = undefined;
    switch (k) {
        .up => move(-1),
        .down => move(1),
        .pgup => if (zoom) {
            scroll += 10;
        } else move(-10),
        .pgdn => if (zoom) {
            scroll -|= 10;
        } else move(10),
        .home => move(-max_rows),
        .end => move(max_rows),
        .left => {
            if (!zoom) return .close;
            zoom = false;
        },
        .esc => {
            if (zoom) {
                zoom = false;
            } else if (filter_n > 0) {
                filter_n = 0;
                rebuild();
            } else return .close;
        },
        .ctrl => |c| if (c == 3) return .close,
        .tab => {
            all_folders = !all_folders;
            rescan();
        },
        .enter, .right => if (r) |x| {
            if (isThis(x)) return .close;
            if (x.has_live and x.live.alive) {
                if (x.live.kind == .bg) {
                    zoom = !zoom;
                    scroll = 0;
                } else flash(true, "open in another terminal (pid {d})", .{x.live.pid});
                return null;
            }
            const p = x.path(&open_b);
            return .{ .open = p };
        },
        .back, .del => if (r) |x| {
            if (isThis(x) or (x.has_live and x.live.alive)) {
                flash(true, "in use: stop it first", .{});
            } else startInput(.confirm_delete, "");
        },
        .char => |c| switch (c) {
            'q' => return .close,
            ' ' => {
                zoom = !zoom;
                scroll = 0;
            },
            'k' => move(-1),
            'j' => move(1),
            '/' => startInput(.search, filter_b[0..filter_n]),
            'n' => startInput(.new_agent, ""),
            'm' => if (r) |x| {
                if (isThis(x)) {
                    flash(true, "this is the session at your prompt: type there", .{});
                } else if (x.has_live and x.live.alive and x.live.kind == .tui) {
                    flash(true, "open in another terminal (pid {d}): type there", .{x.live.pid});
                } else startInput(.message, "");
            },
            'r' => if (r) |x| startInput(.rename, x.title()),
            'f' => if (r) |x| {
                const p = fork(x.path(&pb), x.title()) orelse {
                    flash(true, "could not fork", .{});
                    return null;
                };
                return .{ .open = p };
            },
            'x' => if (r) |x| {
                if (x.has_live and x.live.alive and x.live.kind == .bg and x.live.pid > 0) {
                    _ = linux.kill(x.live.pid, .INT);
                    flash(false, "stopping “{s}”…", .{short(x.title(), 40)});
                } else flash(true, "not running", .{});
            },
            'y', 'd', 'a' => if (r) |x| {
                if (x.has_live and x.live.alive and x.live.state == .waiting) {
                    const ans: []const u8 = switch (c) {
                        'y' => "y",
                        'a' => "a",
                        else => "n",
                    };
                    _ = agents.putSidecar(x.path(&pb), ".answer", ans);
                    flash(false, "{s}", .{if (c == 'd') "denied" else "allowed"});
                } else if (c == 'd') {
                    flash(true, "nothing to deny (⌫ deletes)", .{});
                }
            },
            else => {},
        },
        else => {},
    }
    return null;
}

fn startInput(m: Mode, text: []const u8) void {
    mode = m;
    line_n = @min(text.len, line_b.len);
    @memcpy(line_b[0..line_n], text[0..line_n]);
}

fn inputKey(k: Key) ?Action {
    switch (k) {
        .esc, .left => {
            if (mode == .search) {
                filter_n = 0;
                rebuild();
            }
            mode = .list;
            return null;
        },
        .ctrl => |c| switch (c) {
            3 => {
                mode = .list;
                return null;
            },
            21 => line_n = 0, // Ctrl-U
            else => {},
        },
        .paste_start => pasting = true,
        .paste_end => pasting = false,
        .back => while (line_n > 0) {
            line_n -= 1;
            if ((line_b[line_n] & 0xC0) != 0x80) break;
        },
        .enter => if (pasting) {
            addInput('\n');
        } else return submit(),
        .char => |c| {
            if (mode == .confirm_delete) {
                if (c == 'y' or c == 'Y') return submit();
                mode = .list;
                return null;
            }
            addInput(c);
        },
        .tab => addInput(' '),
        else => {},
    }
    if (mode == .search) {
        filter_n = @min(line_n, filter_b.len);
        @memcpy(filter_b[0..filter_n], line_b[0..filter_n]);
        rebuild();
    }
    return null;
}

fn addInput(c: u8) void {
    if (line_n < line_b.len) {
        line_b[line_n] = c;
        line_n += 1;
    }
}

fn submit() ?Action {
    const m = mode;
    mode = .list;
    const text = std.mem.trim(u8, line_b[0..line_n], " \n\t");
    var pb: [600]u8 = undefined;
    const r = selected();
    const agent = @import("agent.zig");
    switch (m) {
        .list, .search => {},
        .new_agent => if (text.len > 0) {
            if (agents.spawn(text, null, agent.cfg.model, @tagName(tools.mode))) {
                flash(false, "◆ started a background agent · it shows up here in a moment", .{});
                pending_n = @min(text.len, pending_b.len);
                @memcpy(pending_b[0..pending_n], text[0..pending_n]);
                while (pending_n > 0 and (pending_b[pending_n - 1] & 0x80) != 0) pending_n -= 1; // never half a character
                for (pending_b[0..pending_n]) |*c| if (c.* == '\n' or c.* == '\t') {
                    c.* = ' ';
                };
                pending_until = sys.nowNs() + 6 * std.time.ns_per_s;
            } else flash(true, "could not start an agent", .{});
        },
        .message => if (r) |x| if (text.len > 0) {
            const p = x.path(&pb);
            if (x.has_live and x.live.alive and x.live.kind == .bg) {
                if (agents.sendInbox(p, text)) flash(false, "sent · it reads it before its next step", .{}) else flash(true, "could not send", .{});
            } else if (agents.spawn(text, p, agent.cfg.model, @tagName(tools.mode))) {
                flash(false, "◆ continuing “{s}” in the background", .{short(x.title(), 40)});
            } else flash(true, "could not start an agent", .{});
        },
        .rename => if (r) |x| {
            _ = agents.putSidecar(x.path(&pb), ".title", text);
            rescan();
        },
        .confirm_delete => if (r) |x| {
            const t = short(x.title(), 40);
            var tb: [160]u8 = undefined;
            @memcpy(tb[0..t.len], t);
            agents.remove(x.path(&pb));
            move(1);
            rescan();
            flash(false, "deleted “{s}”", .{tb[0..t.len]});
        },
    }
    return null;
}

/// Copy a session to a new file (named for now) with the title "… (fork)". Returns its path.
fn fork(src: []const u8, title: []const u8) ?[]const u8 {
    var body = Buf.init(256 << 20);
    defer body.free();
    const f = sys.open(src, .{ .CLOEXEC = true }, 0) catch return null;
    while (true) {
        const dst = body.extend(1 << 16);
        const got = sys.read(f, dst) catch 0;
        body.truncate(body.len - (dst.len - got));
        if (got == 0) break;
    }
    sys.close(f);
    var p: []const u8 = "";
    const nf = session.newFile(&open_b, &p) orelse return null;
    defer sys.close(nf);
    sys.writeAll(nf, body.items()) catch return null;
    var tb: [200]u8 = undefined;
    _ = agents.putSidecar(p, ".title", std.fmt.bufPrint(&tb, "{s} (fork)", .{cutCols(title, 150)}) catch title);
    return p;
}

// ---- drawing ----

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn bold() []const u8 {
    return if (ui.color) "\x1b[1m" else "";
}

/// Columns of `s` (one per UTF-8 character).
fn cols(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// `s` in at most `w` columns, with "…" when cut (one buffer: use the result before the next call).
fn short(s: []const u8, w: usize) []const u8 {
    const S = struct {
        var b: [600]u8 = undefined;
    };
    if (cols(s) <= w) return s;
    return std.fmt.bufPrint(&S.b, "{s}…", .{std.mem.trimEnd(u8, cutCols(s, w -| 1), " ")}) catch cutCols(s, w);
}

fn cutCols(s: []const u8, w: usize) []const u8 {
    var c: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (c == w) return s[0..i];
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        c += 1;
    }
    return s[0..@min(i, s.len)];
}

/// One screen row being written: tracks columns so parts line up.
const Out = struct {
    b: *Buf,
    col: usize = 0,
    fn sgr(o: *Out, s: []const u8) void {
        o.b.add(s);
    }
    /// `s` with control characters made harmless, in at most `w` columns (… when cut).
    fn text(o: *Out, s: []const u8, w: usize) void {
        if (w == 0) return;
        const fits = cols(s) <= w;
        const room = if (fits) w else w - 1;
        var c: usize = 0;
        var i: usize = 0;
        while (i < s.len and c < room) {
            const ch = s[i];
            const n = std.unicode.utf8ByteSequenceLength(ch) catch 1;
            if (ch < 0x20 or ch == 0x7f or n == 1 and ch >= 0x80) {
                o.b.byte(' ');
            } else if (i + n <= s.len and !(n == 2 and ch == 0xC2 and s[i + 1] < 0xA0)) { // no C1 controls
                o.b.add(s[i .. i + n]);
            } else o.b.byte(' ');
            i += n;
            c += 1;
        }
        o.col += c;
        if (!fits) {
            o.b.add("…");
            o.col += 1;
        }
    }
    fn pad(o: *Out, to: usize) void {
        while (o.col < to) : (o.col += 1) o.b.byte(' ');
    }
};

fn ago(secs: i64, buf: []u8) []const u8 {
    const s = @max(secs, 0);
    if (s < 60) return "now";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@divFloor(s, 60)}) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d}h", .{@divFloor(s, 3600)}) catch "";
    return std.fmt.bufPrint(buf, "{d}d", .{@divFloor(s, 86400)}) catch "";
}

fn dur(secs: u32, buf: []u8) []const u8 {
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch "";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d}m {d}s", .{ secs / 60, secs % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}h {d}m", .{ secs / 3600, secs / 60 % 60 }) catch "";
}

const Look = struct { icon: []const u8, color: []const u8, word: []const u8, detail: []const u8 = "" };

/// How a session shows: icon, color, a state word and a detail line.
fn look(r: *const Row, buf: []u8) Look {
    const spin = spinner[@intCast((sys.nowNs() / (100 * std.time.ns_per_ms)) % spinner.len)];
    if (isThis(r)) return .{ .icon = "●", .color = ui.accent(), .word = "this session", .detail = "at your prompt" };
    if (!r.has_live) return .{ .icon = "○", .color = ui.muted(), .word = "saved" };
    const l = &r.live;
    if (l.alive and l.kind == .tui) return .{ .icon = if (l.state == .running) spin else "◉", .color = ui.accent(), .word = "open in another terminal", .detail = if (l.state == .running) l.doing() else "idle" };
    var db: [32]u8 = undefined;
    return switch (agents.shownState(l)) {
        .waiting => .{ .icon = "?", .color = ui.yellow(), .word = "needs you", .detail = std.fmt.bufPrint(buf, "wants to {s}", .{l.question()}) catch "" },
        .running => .{ .icon = spin, .color = ui.accent(), .word = "running", .detail = std.fmt.bufPrint(buf, "step {d} · {s}", .{ l.step, l.doing() }) catch "" },
        .done => .{ .icon = "✓", .color = ui.green(), .word = "done", .detail = std.fmt.bufPrint(buf, "done in {s}{s}", .{ dur(l.secs, &db), if (l.changed > 0) (std.fmt.bufPrint(buf[100..], " · {d} file{s} changed", .{ l.changed, if (l.changed == 1) "" else "s" }) catch "") else "" }) catch "" },
        .failed => .{ .icon = "✗", .color = ui.red(), .word = "failed", .detail = if (l.alive or l.state == .failed) "failed · see its log" else "ended unexpectedly" },
        .stopped => .{ .icon = "■", .color = ui.yellow(), .word = "stopped", .detail = "stopped · m continues it" },
        .idle => .{ .icon = "○", .color = ui.muted(), .word = "saved" },
    };
}

fn draw() void {
    const w: usize = sys.termCols();
    const h: usize = sys.termRows();
    if (w < 20 or h < 8) return;
    frame.reset();
    frame.add("\x1b[?2026h");
    const b = &frame;
    // header
    {
        var o = Out{ .b = b };
        b.print("\x1b[1;1H", .{});
        o.sgr(ui.accent());
        o.sgr(bold());
        o.text(" ◆ awl", 6);
        o.sgr(ui.plain());
        o.sgr(ui.fg());
        o.text("  agents & sessions", 19);
        var run_n: usize = 0;
        var wait_n: usize = 0;
        for (rows) |*r| if (r.has_live and r.live.alive and r.live.kind == .bg) {
            if (r.live.state == .running) run_n += 1;
            if (r.live.state == .waiting) wait_n += 1;
        };
        var cb: [80]u8 = undefined;
        if (wait_n > 0) {
            o.sgr(ui.yellow());
            o.text(std.fmt.bufPrint(&cb, "   ? {d} need{s} you", .{ wait_n, if (wait_n == 1) "s" else "" }) catch "", 30);
        }
        if (run_n > 0) {
            o.sgr(ui.accent());
            o.text(std.fmt.bufPrint(&cb, "   ◆ {d} running", .{run_n}) catch "", 20);
        }
        var hb: [4096]u8 = undefined;
        var tb2: [4096]u8 = undefined;
        const scope = if (all_folders) "all folders" else tailPath(homeShort(session.start_cwd, &hb), @max(w -| (o.col + 4), 12), &tb2);
        const right_w = @min(cols(scope) + 2, w -| (o.col + 2));
        o.pad(w -| right_w);
        o.sgr(ui.muted());
        o.text(scope, right_w -| 1);
        o.sgr(ui.plain());
        b.add("\x1b[K");
        b.print("\x1b[2;1H{s}", .{ui.muted()});
        for (0..w) |_| b.add("─");
        b.print("{s}\x1b[K", .{ui.plain()});
    }
    const body_top: usize = 3;
    const body_h = h -| 4; // rows 3 .. h-2
    const wide = w >= 110 and !zoom;
    const list_w: usize = if (zoom) 0 else if (wide) @min(@max(w * 45 / 100, 48), 76) else w;
    const list_h: usize = if (zoom) 0 else if (wide) body_h else @max(@min(body_h * 45 / 100, n_lines + 1), @min(body_h, 5));
    // preview area
    const pv_x: usize = if (zoom) 1 else if (wide) list_w + 3 else 1;
    const pv_y: usize = if (zoom or wide) body_top else body_top + list_h + 1;
    const pv_w: usize = if (zoom) w -| 2 else if (wide) w -| (list_w + 4) else w -| 2;
    const pv_h: usize = if (zoom or wide) body_h else body_h -| (list_h + 1);
    // list
    if (sel < top) top = sel;
    if (list_h > 0 and sel >= top + list_h) top = sel + 1 - list_h;
    if (top > 0 and lines[top].header == 0 and top - 1 <= sel and lines[top - 1].header != 0 and sel - (top - 1) < list_h) top -= 1; // keep a section title with its first row
    // the detail column starts after the longest title shown (at most 60% of the room)
    var title_col: usize = 0;
    for (lines[top..@min(n_lines, top + list_h)]) |l| if (l.header == 0) {
        title_col = @max(title_col, cols(shownTitle(&rows[l.row])) + 2);
    };
    title_col = @min(title_col, (list_w -| 11) * 6 / 10);
    for (0..body_h) |i| {
        const y = body_top + i;
        b.print("\x1b[{d};1H", .{y});
        var o = Out{ .b = b };
        if (i < list_h) {
            const li = top + i;
            if (li < n_lines) listLine(&o, li, list_w, title_col);
            if (n_lines == 0 and i == 1) {
                o.sgr(ui.muted());
                o.text(if (filter_n > 0) "   no session matches" else "   no sessions here yet · n starts a background agent", list_w);
                o.sgr(ui.plain());
            }
        }
        if (wide) {
            o.pad(list_w + 1);
            o.sgr(ui.muted());
            o.text("│", 1);
            o.sgr(ui.plain());
        }
        b.add("\x1b[0m\x1b[K");
    }
    if (!wide and !zoom and pv_y > body_top) {
        b.print("\x1b[{d};1H{s}", .{ pv_y - 1, ui.muted() });
        for (0..w) |_| b.add("─");
        b.print("{s}\x1b[K", .{ui.plain()});
    }
    if (selected()) |r| preview(r, pv_x, pv_y, pv_w, pv_h);
    // input or flash line, then the key hints
    b.print("\x1b[{d};1H", .{h - 1});
    var o = Out{ .b = b };
    var cursor: ?[2]usize = null;
    if (mode != .list) {
        const label: []const u8 = switch (mode) {
            .search => " search › ",
            .new_agent => " new background agent › ",
            .message => " message › ",
            .rename => " rename › ",
            .confirm_delete => " delete this session? y/n ",
            .list => "",
        };
        o.sgr(ui.accent());
        o.text(label, w);
        o.sgr(ui.fg());
        const room = w -| (o.col + 1);
        var t = line_b[0..line_n];
        const tc = cols(t);
        if (tc > room) { // show the end of a long line
            var skip = tc - room;
            var i: usize = 0;
            while (skip > 0 and i < t.len) : (skip -= 1) i += std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
            t = t[@min(i, t.len)..];
        }
        o.text(t, room);
        cursor = .{ h - 1, o.col + 1 };
    } else if (flash_n > 0) {
        o.sgr(if (flash_bad) ui.yellow() else ui.green());
        o.text(" ", 1);
        o.text(flash_b[0..flash_n], w -| 2);
    }
    b.add("\x1b[0m\x1b[K");
    b.print("\x1b[{d};1H", .{h});
    o = Out{ .b = b };
    hints(&o, w);
    b.add("\x1b[0m\x1b[K");
    if (cursor) |c| b.print("\x1b[{d};{d}H\x1b[?25h", .{ c[0], c[1] }) else b.add("\x1b[?25l");
    b.add("\x1b[?2026l");
    if (std.mem.eql(u8, frame.items(), last_frame.items())) return;
    out(frame.items());
    last_frame.reset();
    last_frame.add(frame.items());
}

fn listLine(o: *Out, li: usize, w: usize, title_col: usize) void {
    const l = lines[li];
    if (l.header != 0) {
        o.sgr(ui.muted());
        o.text(switch (l.header) {
            1 => "   NEEDS YOU",
            2 => "   RUNNING",
            else => if (all_folders) "   SESSIONS · ALL FOLDERS" else "   SESSIONS",
        }, w);
        o.sgr(ui.plain());
        return;
    }
    const r = &rows[l.row];
    const is_sel = li == sel;
    var lb: [600]u8 = undefined;
    const lk = look(r, &lb);
    o.sgr(ui.accent());
    o.text(if (is_sel) " ▌" else "  ", 2);
    o.sgr(lk.color);
    o.text(" ", 1);
    o.text(lk.icon, 1);
    o.text(" ", 1);
    var ab: [16]u8 = undefined;
    const age = ago(sys.wallSec() - r.mtime, &ab);
    const right = cols(age) + 2;
    const avail = w -| (o.col + right);
    var title_w = avail;
    var detail_w: usize = 0;
    var fb: [400]u8 = undefined;
    const folder = if (all_folders) std.fs.path.basename(r.cwd()) else "";
    const detail = if (folder.len > 0) (std.fmt.bufPrint(&fb, "{s} · {s}", .{ folder, lk.detail }) catch lk.detail) else lk.detail;
    if (avail > 56) {
        title_w = @min(title_col, avail);
        detail_w = avail - title_w;
    }
    o.sgr(if (is_sel) ui.fg() else ui.fg());
    if (is_sel) o.sgr(bold());
    const start = o.col;
    o.text(shownTitle(r), title_w -| 2);
    o.sgr(ui.plain());
    o.pad(start + title_w);
    if (detail_w > 0) {
        o.sgr(if (lk.color.ptr == ui.yellow().ptr) ui.yellow() else ui.muted());
        o.text(detail, detail_w -| 1);
    }
    o.pad(w -| right);
    o.sgr(ui.muted());
    o.text(age, right);
    o.sgr(ui.plain());
}

fn hints(o: *Out, w: usize) void {
    const r = selected();
    const waiting = if (r) |x| x.has_live and x.live.alive and x.live.state == .waiting else false;
    const running = if (r) |x| x.has_live and x.live.alive and x.live.kind == .bg else false;
    const all = [_][2][]const u8{
        .{ "y", "allow" },  .{ "d", "deny" },    .{ "⏎", "open" },    .{ "n", "new agent" }, .{ "m", "message" },
        .{ "x", "stop" },   .{ "r", "rename" },  .{ "f", "fork" },    .{ "⌫", "delete" },   .{ "/", "search" },
        .{ "⇥", if (all_folders) "this folder" else "all folders" }, .{ "space", "zoom" }, .{ "esc", "back" },
    };
    if (mode != .list) {
        o.sgr(ui.muted());
        o.text(if (mode == .confirm_delete) " y deletes · any other key keeps it" else " ⏎ done · esc cancel · ctrl-u clears", w);
        return;
    }
    if (zoom) {
        o.sgr(ui.muted());
        o.text(" PgUp/PgDn scroll · m message · x stop · y/d answer · space or esc back", w);
        return;
    }
    o.text(" ", 1);
    for (all) |kv| {
        if (!waiting and (kv[0][0] == 'y' or (kv[0][0] == 'd' and kv[0].len == 1))) continue;
        if (!running and kv[0][0] == 'x') continue;
        if (running and std.mem.eql(u8, kv[0], "⏎")) continue;
        const need = cols(kv[0]) + cols(kv[1]) + 3;
        if (o.col + need > w) break;
        o.sgr(ui.fg());
        o.sgr(bold());
        o.text(kv[0], 8);
        o.sgr(ui.plain());
        o.sgr(ui.muted());
        o.text(" ", 1);
        o.text(kv[1], 20);
        o.text("  ", 2);
    }
    o.sgr(ui.plain());
}

/// The end of a path in at most `w` columns, from a '/' when cut, behind "…".
fn tailPath(p: []const u8, w: usize, ob: []u8) []const u8 {
    const n = cols(p);
    if (n <= w) return p;
    var i: usize = 0;
    var skip = n - (w -| 1);
    while (skip > 0 and i < p.len) : (skip -= 1) i += std.unicode.utf8ByteSequenceLength(p[i]) catch 1;
    var t = p[@min(i, p.len)..];
    if (std.mem.indexOfScalar(u8, t, '/')) |k| t = t[k..];
    return std.fmt.bufPrint(ob, "…{s}", .{t}) catch t;
}

fn shownTitle(r: *const Row) []const u8 {
    if (r.title().len > 0) return r.title();
    return if (isThis(r)) "new conversation" else "(starting…)";
}

fn homeShort(dir: []const u8, ob: []u8) []const u8 {
    const home = sys.getenv("HOME") orelse "";
    if (home.len > 1 and std.mem.startsWith(u8, dir, home)) return std.fmt.bufPrint(ob, "~{s}", .{dir[home.len..]}) catch dir;
    return dir;
}

// ---- the preview: state, the pending question, the conversation's end ----

var pv = Buf.init(8 << 20); // entries: a style byte ('u' you, 'a' the model, 't' a tool), text, 0
var pv_name_b: [72]u8 = undefined;
var pv_name_n: usize = 0;
var pv_size: u64 = 0;

/// Parse the end of the session (the last 512 KB) into preview entries, when it changed.
fn loadPreview(r: *Row) void {
    var pb: [600]u8 = undefined;
    const p = r.path(&pb);
    var st: linux.Statx = undefined;
    var zb: [600]u8 = undefined;
    const size: u64 = if (linux.errno(linux.statx(linux.AT.FDCWD, sys.z(&zb, p), 0, .{ .SIZE = true }, &st)) == .SUCCESS) st.size else 0;
    if (std.mem.eql(u8, pv_name_b[0..pv_name_n], r.name()) and size == pv_size) return;
    @memcpy(pv_name_b[0..r.name_n], r.name());
    pv_name_n = r.name_n;
    pv_size = size;
    pv.reset();
    last_tool_at = 0;
    last_tool_n = 0;
    const keep: u64 = 512 << 10;
    const from = size -| keep;
    var raw = Buf.init(keep + 4096);
    defer raw.free();
    const f = sys.open(p, .{ .CLOEXEC = true }, 0) catch return;
    defer sys.close(f);
    const dst = raw.extend(@intCast(size - from));
    var got: usize = 0;
    while (got < dst.len) {
        const n = sys.check(linux.pread(f, dst[got..].ptr, dst.len - got, @intCast(from + got))) catch break;
        if (n == 0) break;
        got += n;
    }
    var text = dst[0..got];
    if (from > 0) text = text[(std.mem.indexOfScalar(u8, text, '\n') orelse text.len) -| 0 ..];
    var it = std.mem.splitScalar(u8, text, '\n');
    var cb: [8192]u8 = undefined;
    while (it.next()) |line| {
        if (line.len < 10 or std.mem.startsWith(u8, line, "{\"awl\"")) continue;
        var rb: [16]u8 = undefined;
        const role = agents.field(line, "role", &rb);
        if (std.mem.eql(u8, role, "user")) {
            entry('u', agents.field(line, "content", &cb));
        } else if (std.mem.eql(u8, role, "assistant")) {
            const c = agents.field(line, "content", &cb);
            if (std.mem.trim(u8, c, " \n").len > 0) entry('a', c);
            var rest = line[(std.mem.indexOf(u8, line, "\"tool_calls\":[") orelse continue)..];
            while (std.mem.indexOf(u8, rest, "\"name\":\"")) |ni| {
                var nb: [40]u8 = undefined;
                const name = agents.unquote(rest[ni + 8 ..], &nb);
                rest = rest[ni + 8 ..];
                var ab: [4096]u8 = undefined;
                const args = if (std.mem.indexOf(u8, rest, "\"arguments\":\"")) |ai| agents.unquote(rest[ai + 13 ..], &ab) else "";
                var sb: [600]u8 = undefined;
                var s: []const u8 = "";
                for ([_][]const u8{ "command", "path", "pattern" }) |k| {
                    s = agents.field(args, k, &sb);
                    if (s.len > 0) break;
                }
                var eb: [700]u8 = undefined;
                var rel: [600]u8 = undefined; // paths under the session's folder read as relative
                const n_rel = std.mem.replace(u8, s[0..@min(s.len, 300)], r.cwd(), ".", &rel);
                const shown = rel[0 .. @min(s.len, 300) - n_rel * r.cwd().len + n_rel];
                const tidy = if (std.mem.startsWith(u8, shown, "./")) shown[2..] else shown;
                toolEntry(std.fmt.bufPrint(&eb, "{s} {s}", .{ name, tidy }) catch name);
            }
        }
    }
}

var last_tool_at: usize = 0; // where the last tool entry starts in pv
var last_tool_n: usize = 0; // how many times it repeated

/// A tool line; the same call again right after shows as "×N" on the first one.
fn toolEntry(text: []const u8) void {
    if (last_tool_n > 0) { // the entry before this one was a tool line
        const prev = pv.items()[last_tool_at..];
        const end = std.mem.indexOfScalar(u8, prev, 0) orelse prev.len;
        const body = prev[1..end];
        const plain_end = std.mem.indexOf(u8, body, "  ×") orelse body.len;
        if (last_tool_at + end == pv.len - 1 and std.mem.eql(u8, body[0..plain_end], text)) {
            last_tool_n += 1;
            pv.truncate(last_tool_at);
            pv.byte('t');
            pv.add(text);
            pv.print("  ×{d}", .{last_tool_n});
            pv.byte(0);
            return;
        }
    }
    last_tool_at = pv.len;
    last_tool_n = 1;
    entry('t', text);
}

fn entry(style: u8, text: []const u8) void {
    if (style != 't') last_tool_n = 0;
    pv.byte(style);
    pv.add(text);
    pv.byte(0);
}

/// Word-wrap `text` to `w` columns; each row goes to `rows_out` as style byte, text, '\n'.
fn wrap(rows_out: *Buf, style: u8, text: []const u8, w: usize, first_prefix: []const u8, prefix: []const u8) void {
    if (w < 8) return;
    var lit = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lit.next()) |l0| {
        var l = std.mem.trimEnd(u8, l0, " \r");
        if (style == 'a') l = stripMd(l);
        if (l.len == 0) {
            if (!first) {
                rows_out.byte(style);
                rows_out.byte('\n');
            }
            continue;
        }
        while (l.len > 0) {
            const pre = if (first) first_prefix else prefix;
            first = false;
            const room = w -| cols(pre);
            var take = cutCols(l, room);
            if (take.len < l.len) { // break at the last space
                if (std.mem.lastIndexOfScalar(u8, take, ' ')) |sp| if (sp > take.len / 3) {
                    take = take[0..sp];
                };
            }
            rows_out.byte(style);
            rows_out.add(pre);
            rows_out.add(take);
            rows_out.byte('\n');
            l = std.mem.trimStart(u8, l[take.len..], " ");
        }
    }
}

/// Markdown markers that read as noise in a preview: **, `, leading #s.
fn stripMd(l: []const u8) []const u8 {
    const S = struct {
        var b: [8192]u8 = undefined;
    };
    var s = l;
    while (s.len > 0 and s[0] == '#') s = s[1..];
    s = std.mem.trimStart(u8, s, " ");
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < S.b.len) : (i += 1) {
        if (s[i] == '`') continue;
        if (s[i] == '*' and i + 1 < s.len and s[i + 1] == '*') {
            i += 1;
            continue;
        }
        S.b[n] = s[i];
        n += 1;
    }
    return S.b[0..n];
}

fn preview(r: *Row, x: usize, y: usize, w: usize, h: usize) void {
    if (w < 16 or h < 3) return;
    const b = &frame;
    var rb = Buf.init(1 << 20); // rows: style byte, text, '\n'
    defer rb.free();
    var lb: [600]u8 = undefined;
    const lk = look(r, &lb);
    // head: the title, then state, model, folder, age
    wrap(&rb, 'T', shownTitle(r), w, "", "");
    var hb: [4096]u8 = undefined;
    var tb: [4096]u8 = undefined;
    var ab: [16]u8 = undefined;
    var mb: [1200]u8 = undefined;
    const meta = std.fmt.bufPrint(&mb, "{s} {s} · {s} · {s} · {s}", .{ lk.icon, lk.word, if (r.model().len > 0) r.model() else "?", tailPath(homeShort(r.cwd(), &hb), 36, &tb), ago(sys.wallSec() - r.mtime, &ab) }) catch "";
    wrap(&rb, 'S', meta, w, "", "  ");
    if (r.has_live and r.live.alive and r.live.state == .waiting) {
        rb.add("_\n");
        wrap(&rb, 'Q', lk.detail, w, "? ", "  ");
        wrap(&rb, 'q', "y allow · d deny" ++ "", w, "  ", "  ");
    } else if (lk.detail.len > 0 and !isThis(r) and lk.color.ptr != ui.muted().ptr) {
        wrap(&rb, 'S', lk.detail, w, "  ", "  ");
    }
    rb.add("_\n");
    const head_rows = std.mem.count(u8, rb.items(), "\n");
    // the conversation's end
    loadPreview(r);
    var cv = Buf.init(4 << 20);
    defer cv.free();
    var it = std.mem.splitScalar(u8, pv.items(), 0);
    var prev: u8 = 0;
    while (it.next()) |e| {
        if (e.len == 0) continue;
        const st = e[0];
        const t = e[1..];
        if (st == 'u' and prev != 0) cv.add("_\n");
        switch (st) {
            'u' => wrap(&cv, 'u', cutLines(t, 8), w, "› ", "  "),
            'a' => wrap(&cv, 'a', t, w, "", ""),
            else => { // one row: the tool and what it worked on
                cv.add("t  ▸ ");
                cv.add(short(t, w -| 4));
                cv.byte('\n');
            },
        }
        prev = st;
    }
    if (pv.len == 0) wrap(&cv, 't', "(nothing yet)", w, "", "");
    // show the head, then as much of the end of the conversation as fits
    const total = std.mem.count(u8, cv.items(), "\n");
    const room = h -| @min(head_rows, h);
    const max_scroll = total -| room;
    if (scroll > max_scroll) scroll = max_scroll;
    const first = total -| room -| scroll;
    var row: usize = 0;
    var hit = std.mem.splitScalar(u8, rb.items(), '\n');
    while (hit.next()) |l| {
        if (l.len == 0 or row >= h) continue;
        pvRow(b, x, y + row, w, l);
        row += 1;
    }
    var cit = std.mem.splitScalar(u8, cv.items(), '\n');
    var k: usize = 0;
    while (cit.next()) |l| : (k += 1) {
        if (l.len == 0 or k < first or row >= h) continue;
        pvRow(b, x, y + row, w, l);
        row += 1;
    }
    if (scroll > 0 and h > 0) { // a mark that newer lines are below
        b.print("\x1b[{d};{d}H{s}↓ {d} more{s}", .{ y + h - 1, x + w -| 10, ui.muted(), scroll, ui.plain() });
    }
}

fn pvRow(b: *Buf, x: usize, y: usize, w: usize, l: []const u8) void {
    b.print("\x1b[{d};{d}H", .{ y, x + 1 });
    var o = Out{ .b = b, .col = 0 };
    const st = l[0];
    const t = l[1..];
    switch (st) {
        'T' => {
            o.sgr(ui.fg());
            o.sgr(bold());
        },
        'S', 't' => o.sgr(ui.muted()),
        'Q', 'q' => o.sgr(ui.yellow()),
        'u' => {
            if (std.mem.startsWith(u8, t, "› ")) {
                o.sgr(ui.accent());
                o.text("› ", 2);
                o.sgr(ui.fg());
                o.sgr(bold());
                o.text(t[4..], w -| 2);
                o.sgr(ui.plain());
                return;
            }
            o.sgr(ui.fg());
            o.sgr(bold());
        },
        '_' => return,
        else => o.sgr(ui.fg()),
    }
    o.text(t, w);
    o.sgr(ui.plain());
}

/// The first `n` lines of `s`.
fn cutLines(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (i < s.len) : (i += 1) if (s[i] == '\n') {
        k += 1;
        if (k == n) return s[0..i];
    };
    return s;
}

test "wrap breaks at spaces and keeps prefixes" {
    var b = Buf.init(4096);
    defer b.free();
    wrap(&b, 'a', "one two three four five", 12, "", "");
    try std.testing.expectEqualStrings("aone two\nathree four\nafive\n", b.items());
    b.reset();
    wrap(&b, 'u', "fix the failing test", 12, "› ", "  ");
    try std.testing.expectEqualStrings("u› fix the\nu  failing\nu  test\n", b.items());
}

test "Out.text makes control characters harmless" {
    var b = Buf.init(4096);
    defer b.free();
    var o = Out{ .b = &b };
    o.text("a\x1b]52;c;x\x07b\xc2\x9bc", 40);
    try std.testing.expect(std.mem.indexOfScalar(u8, b.items(), 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, b.items(), 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, b.items(), "\xc2\x9b") == null);
    b.reset();
    o = Out{ .b = &b };
    o.text("abcdefgh", 5);
    try std.testing.expectEqualStrings("abcd…", b.items());
    try std.testing.expectEqual(@as(usize, 5), o.col);
}
