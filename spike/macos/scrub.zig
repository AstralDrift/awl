//! Throwaway spike: can a process hide a secret that arrived in its environment?
//! sysctl(KERN_PROCARGS2) reads the live environment block on the stack, so overwriting the
//! value in place should remove it from what other processes (and `ps eww`) can see.
//! Usage: AWL_KEY=hunter6 scrub     prints what KERN_PROCARGS2 of itself shows before and after.
const std = @import("std");
extern "c" fn sysctl(name: [*]c_int, namelen: c_uint, oldp: ?[*]u8, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn getpid() c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" var environ: [*:null]?[*:0]u8;
var buf: [262144]u8 = undefined;

fn visible(needle: []const u8) bool {
    var mib = [_]c_int{ 1, 49, getpid() };
    var n: usize = buf.len;
    if (sysctl(&mib, 3, &buf, &n, null, 0) != 0) return false;
    return std.mem.indexOf(u8, buf[0..n], needle) != null;
}

pub fn main() u8 {
    var secret_b: [64]u8 = undefined;
    var i: usize = 0;
    while (environ[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (!std.mem.startsWith(u8, s, "AWL_KEY=")) continue;
        const v = s["AWL_KEY=".len..];
        const secret = secret_b[0..@min(v.len, secret_b.len)];
        @memcpy(secret, v[0..secret.len]); // awl's own copy, off the stack
        const before = visible(secret);
        @memset(v, 'x'); // in place: same length, so the block's layout does not change
        const after = visible(secret);
        var ob: [160]u8 = undefined;
        const out = std.fmt.bufPrint(&ob, "AWL_KEY in KERN_PROCARGS2 of this process: before scrub {s}, after scrub {s}\n", .{ if (before) "visible" else "hidden", if (after) "VISIBLE" else "hidden" }) catch return 2;
        _ = write(1, out.ptr, out.len);
        return if (before and !after) 0 else 1;
    }
    return 2;
}
