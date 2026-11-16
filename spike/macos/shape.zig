//! Throwaway spike: a program of awl's shape on Darwin, through libSystem only.
//! What it exercises is what the port needs a Darwin answer for:
//!   mmap'd lazy buffer (buf.zig), a non-blocking stream socket read through poll (http.zig),
//!   fork + execve with a pipe (tools.zig), child-exit notice in the same poll set
//!   (pidfd_open -> kqueue EVFILT_PROC), SIGINT as a readable fd (signalfd -> EVFILT_SIGNAL),
//!   the real path of an open fd (/proc/self/fd -> fcntl F_GETPATH), a directory listing
//!   (getdents64 -> __getdirentries64), peak RSS (/proc/self/status -> getrusage),
//!   own executable path (/proc/self/exe -> _NSGetExecutablePath).
//! `shape` runs all of it and prints one line each; `shape --version` exits at once (startup).
const std = @import("std");

const Kevent = extern struct { ident: usize, filter: i16, flags: u16, fflags: u32, data: isize, udata: usize };
const Pollfd = extern struct { fd: c_int, events: i16, revents: i16 };
const Timeval = extern struct { sec: i64, usec: i32 };
const Rusage = extern struct { utime: Timeval, stime: Timeval, maxrss: isize, rest: [13]isize };

extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn socketpair(domain: c_int, kind: c_int, proto: c_int, fds: *[2]c_int) c_int;
extern "c" fn poll(fds: [*]Pollfd, n: c_uint, timeout_ms: c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn dup2(a: c_int, b: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kqueue() c_int;
extern "c" fn kevent(kq: c_int, changes: ?[*]const Kevent, nchanges: c_int, events: ?[*]Kevent, nevents: c_int, timeout: ?*const anyopaque) c_int;
extern "c" fn sigprocmask(how: c_int, set: *const u32, old: ?*u32) c_int;
extern "c" fn getrusage(who: c_int, ru: *Rusage) c_int;
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) ?*anyopaque;
extern "c" fn __getdirentries64(fd: c_int, buf: [*]u8, len: usize, basep: *i64) isize;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

const F_GETFL = 3;
const F_SETFL = 4;
const F_GETPATH = 50;
const O_NONBLOCK = 0x4;
const O_DIRECTORY = 0x100000;
const EVFILT_SIGNAL: i16 = -6;
const EVFILT_PROC: i16 = -5;
const EV_ADD = 0x1;
const NOTE_EXIT = 0x80000000;
const SIGINT = 2;

var out_b: [4096]u8 = undefined;
fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&out_b, fmt ++ "\n", args) catch return;
    _ = write(1, s.ptr, s.len);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "--version")) {
        _ = write(1, "shape 0\n", 8);
        return 0;
    }

    // buf.zig: one lazy 4 MB region, 64 KB touched
    const region: [*]u8 = @ptrCast(mmap(null, 4 << 20, 3, 0x1002, -1, 0) orelse return 1); // PROT_READ|WRITE, MAP_ANON|MAP_PRIVATE
    @memset(region[0 .. 64 << 10], 'x');

    // signalfd -> kqueue EVFILT_SIGNAL (SIGINT blocked, counted by the kqueue)
    const kq = kqueue();
    const mask: u32 = 1 << (SIGINT - 1);
    _ = sigprocmask(1, &mask, null); // SIG_BLOCK
    var ch = [_]Kevent{.{ .ident = SIGINT, .filter = EVFILT_SIGNAL, .flags = EV_ADD, .fflags = 0, .data = 0, .udata = 0 }};
    say("kqueue signal filter: {s}", .{if (kevent(kq, &ch, 1, null, 0, null) == 0) "ok" else "FAIL"});

    // http.zig: a non-blocking stream socket, read when poll says so
    var sp: [2]c_int = undefined;
    if (socketpair(1, 1, 0, &sp) != 0) return 1; // AF_UNIX, SOCK_STREAM
    _ = fcntl(sp[0], F_SETFL, fcntl(sp[0], F_GETFL) | O_NONBLOCK);
    _ = write(sp[1], "data: {}\n\n", 10);
    var one = [_]Pollfd{.{ .fd = sp[0], .events = 1, .revents = 0 }};
    var rb: [256]u8 = undefined;
    const pr = poll(&one, 1, 1000);
    say("socket via poll: {s}", .{if (pr == 1 and read(sp[0], &rb, rb.len) == 10) "ok" else "FAIL"});

    // tools.zig: fork + execve, output on a pipe, exit seen in the same poll set
    var p: [2]c_int = undefined;
    if (pipe(&p) != 0) return 1;
    const pid = fork();
    if (pid == 0) {
        _ = dup2(p[1], 1);
        _ = close(p[0]);
        const av = [_:null]?[*:0]const u8{ "/bin/echo", "child-ok" };
        const ev = [_:null]?[*:0]const u8{};
        _ = execve("/bin/echo", &av, &ev);
        _exit(127);
    }
    _ = close(p[1]);
    ch[0] = .{ .ident = @intCast(pid), .filter = EVFILT_PROC, .flags = EV_ADD, .fflags = NOTE_EXIT, .data = 0, .udata = 0 };
    const reg = kevent(kq, &ch, 1, null, 0, null); // ESRCH here would mean it already exited
    var two = [_]Pollfd{ .{ .fd = p[0], .events = 1, .revents = 0 }, .{ .fd = kq, .events = 1, .revents = 0 } };
    var got: usize = 0;
    var exited = false;
    var rounds: u32 = 0;
    while (rounds < 100 and !(exited and got > 0)) : (rounds += 1) {
        if (poll(&two, 2, 2000) <= 0) break;
        if (two[0].revents != 0) {
            const n = read(p[0], rb[got..].ptr, rb.len - got);
            if (n > 0) got += @intCast(n) else two[0].fd = -1;
        }
        if (two[1].revents != 0) {
            var ev: [1]Kevent = undefined;
            const zero = [2]i64{ 0, 0 };
            if (kevent(kq, null, 0, &ev, 1, &zero) == 1 and ev[0].filter == EVFILT_PROC) exited = true;
        }
    }
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    say("fork+execve, pipe and kqueue(EVFILT_PROC) in one poll: {s} (registered {d}, exit seen {}, status {d}, output \"{s}\")", .{ if (reg == 0 and exited and status == 0 and got == 9) "ok" else "FAIL", reg, exited, status, std.mem.trim(u8, rb[0..got], "\n") });

    // sandbox.zig resolve(): the kernel's path of an open fd
    const dfd = open(".", O_DIRECTORY);
    var path: [1024]u8 = undefined;
    say("fcntl(F_GETPATH) of \".\": {s}", .{if (fcntl(dfd, F_GETPATH, &path) == 0) std.mem.sliceTo(&path, 0) else "FAIL"});
    const tfd = open("/tmp", O_DIRECTORY);
    say("fcntl(F_GETPATH) of \"/tmp\": {s}", .{if (fcntl(tfd, F_GETPATH, &path) == 0) std.mem.sliceTo(&path, 0) else "FAIL"});

    // getdents64 -> __getdirentries64
    var db: [8192]u8 align(8) = undefined;
    var base: i64 = 0;
    const dn = __getdirentries64(dfd, &db, db.len, &base);
    var entries: u32 = 0;
    var off: usize = 0;
    while (dn > 0 and off < @as(usize, @intCast(dn))) : (entries += 1) off += std.mem.readInt(u16, db[off + 16 ..][0..2], .little); // d_reclen
    say("__getdirentries64: {d} bytes, {d} entries", .{ dn, entries });

    // /proc/self/exe
    var size: u32 = path.len;
    say("_NSGetExecutablePath: {s}", .{if (_NSGetExecutablePath(&path, &size) == 0) std.mem.sliceTo(&path, 0) else "FAIL"});

    // /proc/self/status VmHWM
    var ru: Rusage = undefined;
    _ = getrusage(0, &ru);
    say("getrusage ru_maxrss: {d} KB", .{@divTrunc(ru.maxrss, 1024)});
    return 0;
}
