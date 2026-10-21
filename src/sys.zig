//! Thin layer over raw Linux syscalls. No libc, no std.Io.
const std = @import("std");
const linux = std.os.linux;

pub const fd_t = i32;
pub const stdin: fd_t = 0;
pub const stdout: fd_t = 1;
pub const stderr: fd_t = 2;

pub const Error = error{ Sys, Interrupted, NotFound, Exists, Access, Timeout };

/// Convert a raw syscall return into a value or an error. Last errno kept for messages.
pub var last_errno: linux.E = .SUCCESS;
pub fn check(rc: usize) Error!usize {
    const e = linux.errno(rc);
    if (e == .SUCCESS) return rc;
    last_errno = e;
    return switch (e) {
        .INTR => error.Interrupted,
        .NOENT => error.NotFound,
        .EXIST => error.Exists,
        .ACCES, .PERM => error.Access,
        else => error.Sys,
    };
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var b = bytes;
    while (b.len > 0) {
        const n = check(linux.write(fd, b.ptr, b.len)) catch |e| {
            if (e == error.Interrupted) continue;
            return e;
        };
        b = b[n..];
    }
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) return check(linux.read(fd, buf.ptr, buf.len)) catch |e| {
        if (e == error.Interrupted) continue;
        return e;
    };
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// Zero-terminate `s` into `buf` for syscalls that need a C path.
pub fn z(buf: []u8, s: []const u8) [:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn open(path: []const u8, flags: linux.O, mode: linux.mode_t) Error!fd_t {
    var pb: [4096]u8 = undefined;
    return @intCast(try check(linux.openat(linux.AT.FDCWD, z(&pb, path), flags, mode)));
}

pub fn exit(code: u8) noreturn {
    linux.exit_group(code);
}

pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn wallSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

pub fn isatty(fd: fd_t) bool {
    var ws: std.posix.winsize = undefined;
    return linux.errno(linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws))) == .SUCCESS;
}

pub fn termCols() u16 {
    var ws: std.posix.winsize = undefined;
    if (linux.errno(linux.ioctl(stdout, linux.T.IOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS or ws.col == 0) return 80;
    return ws.col;
}

/// Environment, set once from main.
pub var envp: []const [*:0]const u8 = &.{};
pub var envp_raw: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{};
pub fn getenv(name: []const u8) ?[]const u8 {
    for (envp) |e| {
        const s = std.mem.span(e);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) return s[name.len + 1 ..];
    }
    return null;
}

/// Read a whole small file into `buf`. Returns the filled slice.
pub fn readFile(path: []const u8, buf: []u8) Error![]u8 {
    const fd = try open(path, .{ .CLOEXEC = true }, 0);
    defer close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = try read(fd, buf[n..]);
        if (r == 0) break;
        n += r;
    }
    return buf[0..n];
}

pub fn exists(path: []const u8) bool {
    var pb: [4096]u8 = undefined;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, z(&pb, path), linux.F_OK, 0)) == .SUCCESS;
}

/// Peak resident set size in KB (VmHWM from /proc/self/status).
pub fn peakRssKb() u64 {
    return procStatus("VmHWM:");
}
pub fn rssKb() u64 {
    return procStatus("VmRSS:");
}
fn procStatus(key: []const u8) u64 {
    var buf: [2048]u8 = undefined;
    const s = readFile("/proc/self/status", &buf) catch return 0;
    const i = std.mem.indexOf(u8, s, key) orelse return 0;
    var it = std.mem.tokenizeAny(u8, s[i + key.len ..], " \t");
    const num = it.next() orelse return 0;
    return std.fmt.parseInt(u64, num, 10) catch 0;
}

/// SIGINT and SIGPIPE are blocked; SIGINT is read from this fd instead.
pub var sigfd: fd_t = -1;
pub fn setupSignals() void {
    var set = linux.sigemptyset();
    linux.sigaddset(&set, .INT);
    linux.sigaddset(&set, .PIPE);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &set, null);
    var only_int = linux.sigemptyset();
    linux.sigaddset(&only_int, .INT);
    sigfd = @intCast(check(linux.signalfd(-1, &only_int, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC)) catch return);
}
pub fn drainSignals() void {
    var info: [4]linux.signalfd_siginfo = undefined;
    while (linux.errno(linux.read(sigfd, @ptrCast(&info), @sizeOf(@TypeOf(info)))) == .SUCCESS) {}
}
/// Unblock everything; called in a forked child before execve.
pub fn unblockAll() void {
    const empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
}
