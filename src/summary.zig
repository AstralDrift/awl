//! AWL_SUMMARY=<path>: when a -p run ends, one JSON object saying what happened, for programs
//! that run awl (docs/embedding.md, "Run summary"). Off unless set: nothing is recorded and
//! the buffers below are never touched.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const bufm = @import("buf.zig");
const Buf = bufm.Buf;

pub const version = 1;

pub var path: ?[]const u8 = null;
pub var steps: usize = 0; // model replies received

var names: [16][32]u8 = undefined; // tool name -> calls; more than 16 names share the last slot
var name_n: [16]u8 = undefined;
var counts: [16]usize = .{0} ** 16;
var n_names: usize = 0;
var cmds = Buf.init(4 << 20); // the "commands" array's entries, comma-separated
var err_b: [512]u8 = undefined;
var err_n: usize = 0;

/// How one bash call ended, set by tools.zig as the call runs (not_run unless it started).
pub const Ran = union(enum) { not_run, exited: u32, timed_out, interrupted, background: usize };
pub var ran: Ran = .not_run;

pub fn on() bool {
    return path != null;
}

/// The last error awl reported (ui.err), kept for "error".
pub fn noteError(comptime f: []const u8, a: anytype) void {
    if (!on()) return;
    err_n = if (std.fmt.bufPrint(&err_b, f, a)) |m| m.len else |_| err_b.len;
}

/// One tool call and its result, as the model got it.
pub fn call(name: []const u8, args: []const u8, result: []const u8) void {
    if (!on()) return;
    count(name);
    if (!std.mem.eql(u8, name, "bash")) return;
    if (cmds.len > 0) cmds.byte(',');
    cmds.add("{\"command\":");
    const parsed = std.json.parseFromSlice(struct { command: []const u8 }, std.heap.page_allocator, args, .{ .ignore_unknown_fields = true }) catch null;
    defer if (parsed) |p| p.deinit();
    if (parsed) |p| bufm.str(&cmds, p.value.command) else cmds.add("null");
    switch (ran) {
        .exited => |c| cmds.print(",\"exit\":{d}}}", .{c}),
        .timed_out => cmds.add(",\"timed_out\":true}"),
        .interrupted => cmds.add(",\"interrupted\":true}"),
        .background => |j| cmds.print(",\"background\":{d}}}", .{j}),
        .not_run => {
            cmds.add(",\"not_run\":");
            bufm.str(&cmds, notRunReason(result));
            cmds.byte('}');
        },
    }
    ran = .not_run;
}

fn count(name: []const u8) void {
    const k = @min(name.len, 32);
    for (0..n_names) |i| if (std.mem.eql(u8, names[i][0..name_n[i]], name[0..k])) {
        counts[i] += 1;
        return;
    };
    const i = @min(n_names, names.len - 1);
    @memcpy(names[i][0..k], name[0..k]);
    name_n[i] = @intCast(k);
    counts[i] += 1;
    n_names = @min(n_names + 1, names.len);
}

/// Why a bash call did not run, from the result the model got (one of the refusals in
/// docs/embedding.md, "Tool results"): one line, at most 300 bytes.
fn notRunReason(result: []const u8) []const u8 {
    const first = result[0 .. std.mem.indexOfScalar(u8, result, '\n') orelse result.len];
    if (first.len <= 300) return first;
    var n: usize = 300; // cut at a UTF-8 boundary
    while (n > 0 and first[n] & 0xC0 == 0x80) n -= 1;
    return first[0..n];
}

test "notRunReason: first line, at most 300 bytes, whole code points" {
    try std.testing.expectEqualStrings("not run: AWL_NETWORK=off: x", notRunReason("not run: AWL_NETWORK=off: x\nmore"));
    try std.testing.expectEqualStrings("", notRunReason(""));
    var long: [310]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectEqual(@as(usize, 300), notRunReason(&long).len);
    const s = "é" ** 150 ++ "z"; // 300 bytes of é, then a byte that does not fit
    try std.testing.expectEqualStrings("é" ** 150, notRunReason(s));
    const s2 = "a" ** 299 ++ "é"; // é straddles byte 300: dropped whole
    try std.testing.expectEqualStrings("a" ** 299, notRunReason(s2));
}

pub const Status = enum { done, step_limit, error_, cancelled };

/// Write the summary (temp file, then rename, so a reader never sees half of it). A failure
/// to write is ignored: the run's own exit status stands.
pub fn write(status: Status, exit: u8, session: []const u8, files: anytype, awl: []const u8) void {
    const p = path orelse return;
    var o = Buf.init(cmds.len + 64 * 1024);
    defer o.free();
    o.print("{{\"version\":{d},\"awl\":", .{version});
    bufm.str(&o, awl);
    o.add(",\"status\":\"");
    o.add(if (status == .error_) "error" else @tagName(status));
    o.print("\",\"exit\":{d},\"steps\":{d},\"tool_calls\":{{", .{ exit, steps });
    for (0..n_names) |i| {
        if (i > 0) o.byte(',');
        bufm.str(&o, names[i][0..name_n[i]]);
        o.print(":{d}", .{counts[i]});
    }
    o.add("},\"commands\":[");
    o.add(cmds.items());
    o.add("],\"files_written\":[");
    for (0..files.n) |i| {
        if (i > 0) o.byte(',');
        bufm.str(&o, files.buf[i][0..files.len[i]]);
    }
    o.add("],\"session\":");
    bufm.str(&o, session);
    if (status == .error_) {
        o.add(",\"error\":");
        bufm.str(&o, err_b[0..err_n]);
    }
    o.add("}\n");

    var tb: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tb, "{s}.tmp{d}", .{ p, linux.getpid() }) catch return;
    const fd = sys.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600) catch return;
    sys.writeAll(fd, o.items()) catch {};
    sys.close(fd);
    var z1: [4200]u8 = undefined;
    var z2: [4200]u8 = undefined;
    if (linux.errno(linux.renameat(linux.AT.FDCWD, sys.z(&z1, tmp), linux.AT.FDCWD, sys.z(&z2, p))) != .SUCCESS)
        _ = linux.unlinkat(linux.AT.FDCWD, sys.z(&z1, tmp), 0);
}
