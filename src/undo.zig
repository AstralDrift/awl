//! /undo: before a turn first changes a file (write, edit), its bytes are saved once;
//! undo puts the newest turn's files back and removes the files that turn created.
//! Changes made by shell commands are not tracked.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;

const max_file = 16 << 20; // larger files are not saved (and say so)

// Records, newest last: turn u32, existed u8, path_len u16, len u32, path, bytes.
var log = Buf.init(512 << 20);
var turn: u32 = 0;

pub fn newTurn() void {
    turn += 1;
}

pub fn current() u32 {
    return turn;
}

/// The newest turn with saved files (0: none).
pub fn newest() u32 {
    var off: usize = 0;
    var last: u32 = 0;
    while (off < log.len) {
        const r = at(off);
        last = r.turn;
        off = r.end;
    }
    return last;
}

/// Undo every turn from `from` on, newest first (rewind). Returns files restored or removed.
pub fn undoFrom(from: u32, write: *const fn ([]const u8, []const []const u8, *Buf) bool, out: *Buf) usize {
    var n: usize = 0;
    while (from > 0 and log.len > 0 and newest() >= from) n += undo(write, out);
    return n;
}

const Rec = struct { turn: u32, existed: bool, path: []const u8, bytes: []const u8, end: usize };

fn at(off: usize) Rec {
    const b = log.items();
    const tn = std.mem.readInt(u32, b[off..][0..4], .little);
    const existed = b[off + 4] == 1;
    const pl = std.mem.readInt(u16, b[off + 5 ..][0..2], .little);
    const n = std.mem.readInt(u32, b[off + 7 ..][0..4], .little);
    const p = off + 11;
    return .{ .turn = tn, .existed = existed, .path = b[p .. p + pl], .bytes = b[p + pl .. p + pl + n], .end = p + pl + n };
}

/// Save `path` as it is now, unless this turn already saved it. Returns false when
/// the file is too large to save (the change still happens).
pub fn snapshot(path: []const u8) bool {
    if (path.len > std.math.maxInt(u16)) return false;
    var off: usize = 0;
    while (off < log.len) {
        const r = at(off);
        if (r.turn == turn and std.mem.eql(u8, r.path, path)) return true;
        off = r.end;
    }
    const start = log.len;
    var hdr: [11]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], turn, .little);
    std.mem.writeInt(u16, hdr[5..7], @intCast(path.len), .little);
    const fd = sys.open(path, .{ .CLOEXEC = true }, 0) catch |e| {
        if (e != error.NotFound) return false;
        hdr[4] = 0; // did not exist: undo removes it
        std.mem.writeInt(u32, hdr[7..11], 0, .little);
        log.add(&hdr);
        log.add(path);
        return true;
    };
    defer sys.close(fd);
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) != .SUCCESS or st.size > max_file) return false;
    hdr[4] = 1;
    log.add(&hdr);
    log.add(path);
    const dst = log.extend(st.size);
    var got: usize = 0;
    while (got < dst.len) {
        const n = sys.read(fd, dst[got..]) catch 0;
        if (n == 0) break;
        got += n;
    }
    if (got != st.size or dst.len != st.size) { // short read or log full: drop the record
        log.truncate(start);
        return false;
    }
    std.mem.writeInt(u32, log.items()[start + 7 ..][0..4], @intCast(got), .little);
    return true;
}

/// Undo the newest turn that changed files. Lists what happened in `out`; returns the
/// number of files restored or removed (0: nothing to undo).
pub fn undo(write: *const fn ([]const u8, []const []const u8, *Buf) bool, out: *Buf) usize {
    if (log.len == 0) return 0;
    // find the newest turn and where its records start
    var off: usize = 0;
    var last: u32 = 0;
    while (off < log.len) {
        const r = at(off);
        last = r.turn;
        off = r.end;
    }
    var first: usize = 0;
    off = 0;
    var found = false;
    while (off < log.len) {
        const r = at(off);
        if (r.turn == last and !found) {
            first = off;
            found = true;
        }
        off = r.end;
    }
    var n: usize = 0;
    var tmp = Buf.init(4096);
    defer tmp.free();
    off = first;
    while (off < log.len) {
        const r = at(off);
        off = r.end;
        if (r.existed) {
            tmp.reset();
            if (write(r.path, &.{r.bytes}, &tmp)) {
                out.print("restored {s}\n", .{r.path});
                n += 1;
            } else out.print("could not restore {s}: {s}\n", .{ r.path, tmp.items() });
        } else {
            var pb: [4096]u8 = undefined;
            const rc = linux.unlinkat(linux.AT.FDCWD, sys.z(&pb, r.path), 0);
            if (linux.errno(rc) == .SUCCESS or linux.errno(rc) == .NOENT) {
                out.print("removed {s} (created by that turn)\n", .{r.path});
                n += 1;
            } else out.print("could not remove {s}\n", .{r.path});
        }
    }
    log.truncate(first);
    return n;
}

const t = std.testing;

fn fakeWrite(path: []const u8, parts: []const []const u8, _: *Buf) bool {
    const fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644) catch return false;
    defer sys.close(fd);
    for (parts) |p| sys.writeAll(fd, p) catch return false;
    return true;
}

test "undo restores the newest turn, then the one before" {
    log.reset(); // other tests' edits were saved too
    var pb: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&pb, "/tmp/awl-undo-{d}", .{linux.getpid()});
    var zb: [80]u8 = undefined;
    _ = linux.mkdirat(linux.AT.FDCWD, sys.z(&zb, dir), 0o755);
    var ab: [96]u8 = undefined;
    const a = try std.fmt.bufPrint(&ab, "{s}/a.txt", .{dir});
    var nb: [96]u8 = undefined;
    const new = try std.fmt.bufPrint(&nb, "{s}/new.txt", .{dir});
    var tmp = Buf.init(4096);
    defer tmp.free();
    _ = fakeWrite(a, &.{"one\n"}, &tmp);

    newTurn(); // turn 1: a.txt one -> two
    try t.expect(snapshot(a));
    _ = fakeWrite(a, &.{"two\n"}, &tmp);
    newTurn(); // turn 2: a.txt two -> three (saved once), new.txt created
    try t.expect(snapshot(a));
    _ = fakeWrite(a, &.{"three\n"}, &tmp);
    try t.expect(snapshot(a));
    _ = fakeWrite(a, &.{"four\n"}, &tmp);
    try t.expect(snapshot(new));
    _ = fakeWrite(new, &.{"x"}, &tmp);

    var out = Buf.init(4096);
    defer out.free();
    try t.expectEqual(@as(usize, 2), undo(&fakeWrite, &out));
    var rb: [64]u8 = undefined;
    try t.expectEqualStrings("two\n", try sys.readFile(a, &rb));
    try t.expectError(error.NotFound, sys.readFile(new, &rb));
    try t.expectEqual(@as(usize, 1), undo(&fakeWrite, &out));
    try t.expectEqualStrings("one\n", try sys.readFile(a, &rb));
    try t.expectEqual(@as(usize, 0), undo(&fakeWrite, &out));
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, a), 0);
    _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&zb, dir), linux.AT.REMOVEDIR);
}
