//! Throwaway probe tool: can this process read another process's arguments and environment?
//! Usage: procargs <pid> <needle>. Prints one line; exit 0 when the needle was found.
//! (sysctl KERN_PROCARGS2: the kernel hides the environment of Apple's own binaries, so aim it
//! at something else.)
const std = @import("std");
extern "c" fn sysctl(name: [*]c_int, namelen: c_uint, oldp: ?[*]u8, oldlenp: *usize, newp: ?*anyopaque, newlen: usize) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn __error() *c_int;
var buf: [262144]u8 = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len < 3) return 2;
    var mib = [_]c_int{ 1, 49, std.fmt.parseInt(c_int, std.mem.span(argv[1]), 10) catch return 2 }; // CTL_KERN, KERN_PROCARGS2
    var n: usize = buf.len;
    const rc = sysctl(&mib, 3, &buf, &n, null, 0);
    const found = rc == 0 and std.mem.indexOf(u8, buf[0..n], std.mem.span(argv[2])) != null;
    var ob: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&ob, "procargs2 rc {d} errno {d} bytes {d} {s}\n", .{ rc, if (rc == 0) 0 else __error().*, if (rc == 0) n else 0, if (found) "FOUND" else "not-found" }) catch return 2;
    _ = write(1, s.ptr, s.len);
    return if (found) 0 else 1;
}
