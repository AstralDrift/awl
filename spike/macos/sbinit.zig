//! Throwaway spike: what the sandbox costs per command, three ways.
//!   plain      fork + execve /usr/bin/true
//!   per-command  fork, sandbox_init(profile text) in the child, execve   (no sandbox-exec binary)
//!   holder     one child calls sandbox_init once, then forks + execs every command itself
//! and a check that sandbox_init with raw profile text (flags 0) really confines the caller.
//! Usage: sbinit <profile.sb with no (param ...)> <runs> <path outside the project> <path inside>
//!        [<first sh command> <second sh command>]   (the holder job check)
const std = @import("std");

extern "c" fn sandbox_init(profile: [*:0]const u8, flags: u64, errorbuf: *?[*:0]u8) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn fork() c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn clock_gettime_nsec_np(clock: c_int) u64;

var profile: [65536:0]u8 = undefined;
var out_b: [512]u8 = undefined;
fn say(comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&out_b, fmt ++ "\n", args) catch return;
    _ = write(1, s.ptr, s.len);
}
fn now() u64 {
    return clock_gettime_nsec_np(8); // CLOCK_UPTIME_RAW
}
fn confine() void {
    var err: ?[*:0]u8 = null;
    if (sandbox_init(&profile, 0, &err) != 0) {
        say("sandbox_init failed: {s}", .{if (err) |e| std.mem.span(e) else "?"});
        _exit(3);
    }
}
const true_argv = [_:null]?[*:0]const u8{"/usr/bin/true"};
const no_env = [_:null]?[*:0]const u8{};

/// Mean microseconds for `runs` commands; `sandboxed`: each child confines itself first.
fn loop(runs: u32, sandboxed: bool) u64 {
    const t0 = now();
    var i: u32 = 0;
    while (i < runs) : (i += 1) {
        const pid = fork();
        if (pid == 0) {
            if (sandboxed) confine();
            _ = execve("/usr/bin/true", &true_argv, &no_env);
            _exit(127);
        }
        var st: c_int = 0;
        _ = waitpid(pid, &st, 0);
        if (st != 0) say("a command failed: status {d}", .{st});
    }
    return (now() - t0) / runs / 1000;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len < 5) return 2;
    const fd = open(argv[1], 0);
    if (fd < 0) return 2;
    var n: usize = 0;
    while (n < profile.len) {
        const r = read(fd, profile[n..].ptr, profile.len - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    profile[n] = 0;
    const runs = std.fmt.parseInt(u32, std.mem.span(argv[2]), 10) catch 100;

    // does it confine? a child applies the profile, then tries one write outside and one inside
    var st: c_int = 0;
    var pid = fork();
    if (pid == 0) {
        confine();
        const outside = open(argv[3], 0x201, @as(c_int, 0o600)); // O_WRONLY|O_CREAT
        const inside = open(argv[4], 0x201, @as(c_int, 0o600));
        _exit(if (outside < 0 and inside >= 0) 0 else 1);
    }
    _ = waitpid(pid, &st, 0);
    say("sandbox_init(profile text, 0): {s}", .{if (st == 0) "ok (write outside the project refused, inside allowed)" else "FAIL"});

    _ = loop(20, false); // warm up
    say("plain fork+execve:               {d} us per command", .{loop(runs, false)});
    say("sandbox_init in each child:      {d} us per command", .{loop(runs, true)});
    pid = fork();
    if (pid == 0) {
        const t0 = now();
        confine();
        const once = (now() - t0) / 1000;
        say("holder (sandbox_init once):      {d} us per command, after {d} us once per session", .{ loop(runs, false), once });
        _exit(0);
    }
    _ = waitpid(pid, &st, 0);

    // Jobs: two commands started one after the other by the same sandboxed holder. The first
    // leaves a background process; the second must be able to signal it (two sandbox-exec runs
    // cannot: probes.sh). argv[5] and argv[6] are the two /bin/sh command lines.
    if (argv.len >= 7) {
        pid = fork();
        if (pid == 0) {
            confine();
            var last: c_int = 1;
            for ([_][*:0]const u8{ argv[5], argv[6] }) |cmd| {
                const c = fork();
                if (c == 0) {
                    const av = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
                    _ = execve("/bin/sh", &av, &no_env);
                    _exit(127);
                }
                _ = waitpid(c, &last, 0);
            }
            _exit(if (last == 0) 0 else 1);
        }
        _ = waitpid(pid, &st, 0);
        say("holder: a later command stops an earlier command's background job: {s}", .{if (st == 0) "ok" else "FAIL"});
    }
    return 0;
}
