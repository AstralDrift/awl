//! Sandbox for the commands the model runs (bash, background jobs, grep, find).
//! One bubblewrap sandbox per session (the holder); every command joins its namespaces, so
//! commands share localhost and see each other's processes but nothing of the host's.
//! Inside: the filesystem read-only except the project (git root or cwd), /tmp, build caches
//! and AWL_SANDBOX_WRITE; secrets, /run/user and sockets under /tmp hidden; the project's
//! .git/config, .git/hooks, AGENTS.md and .agents read-only; no network (AWL_SANDBOX_NET=on keeps
//! it); no nested user namespaces; an environment built from an allowlist.
//! read/write/edit follow the same rules in-process, after resolving symlinks.
//! AWL_SANDBOX=off turns it all off. Without /usr/bin/bwrap the model's commands are refused.
//! The user's own !cmd is never sandboxed.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

const bwrap = "/usr/bin/bwrap";
pub var on = false; // commands run in the sandbox
pub var missing = false; // wanted but no bwrap: the model's commands are refused
pub var enforce = false; // path rules apply (everything but AWL_SANDBOX=off)
pub var net = false; // AWL_SANDBOX_NET=on: the session sandbox keeps the host network
var root_b: [4096]u8 = undefined;
pub var root: []const u8 = "";
var home: []const u8 = "";
var extra_b: [2048]u8 = undefined;
var extra: []const u8 = ""; // AWL_SANDBOX_WRITE, ':'-separated

/// Paths hidden from the model (empty tmpfs in the sandbox; read refuses them).
const secrets = [_][]const u8{ "/.ssh", "/.gnupg", "/.aws", "/.config/gh", "/.local/state/omarchy", "/.password-store", "/.local/share/keyrings", "/.docker", "/.kube" };
const sockets = [_][]const u8{ "/run/docker.sock", "/var/run/docker.sock" };
const caches = [_][]const u8{ "/.cache", "/.npm", "/.cargo/registry", "/go/pkg" };
/// Project paths that shape what runs outside the sandbox or what the next session is told:
/// read-only to commands; write/edit need the user's approval every time.
const guarded = [_][]const u8{ "/.git/config", "/.git/hooks", "/AGENTS.md", "/.agents" };

pub fn setup(project_root: []const u8) void {
    home = sys.getenv("HOME") orelse "";
    enforce = !std.mem.eql(u8, sys.getenv("AWL_SANDBOX") orelse "on", "off");
    on = enforce and sys.exists(bwrap);
    missing = enforce and !on;
    net = std.mem.eql(u8, sys.getenv("AWL_SANDBOX_NET") orelse "off", "on");
    const n = @min(project_root.len, root_b.len);
    @memcpy(root_b[0..n], project_root[0..n]);
    root = root_b[0..n];
    if (sys.getenv("AWL_SANDBOX_WRITE")) |w| {
        const m = @min(w.len, extra_b.len);
        @memcpy(extra_b[0..m], w[0..m]);
        extra = extra_b[0..m];
    }
}

/// One line for the welcome screen and the system prompt.
pub fn describe(buf: []u8) []const u8 {
    if (missing) return "no sandbox: install bubblewrap to let the model run commands (or AWL_SANDBOX=off)";
    if (!on) return "sandbox off";
    return std.fmt.bufPrint(buf, "sandbox: writes only to the project, /tmp and caches; network {s}", .{if (net) "on" else "off (bash network: true asks the user for one command)"}) catch "sandbox on";
}

// ---- the session sandbox ----

var holder: linux.pid_t = 0; // the bwrap process (our child)
var holder_out: i32 = -1; // its info/stderr pipe, kept open while it runs
var pidfd: i32 = -1; // the sandbox's first process; setns on it joins its namespaces at once
// (one namespace file at a time fails: the kernel refuses the mount namespace with EPERM)
const all_ns = linux.CLONE.NEWUSER | linux.CLONE.NEWNS | linux.CLONE.NEWNET | linux.CLONE.NEWPID;

const Args = struct {
    v: [256:null]?[*:0]const u8 = undefined,
    n: usize = 0,
    zs: ZStrings = .{},
    fn add(self: *Args, s: [*:0]const u8) void {
        if (self.n < self.v.len - 8) {
            self.v[self.n] = s;
            self.n += 1;
        }
    }
    fn addAll(self: *Args, ss: []const [*:0]const u8) void {
        for (ss) |s| self.add(s);
    }
    fn bindIf(self: *Args, how: [*:0]const u8, p: []const u8) void {
        if (!sys.exists(p)) return;
        const z = self.zs.z(p);
        self.addAll(&.{ how, z, z });
    }
};

/// bwrap's options for the sandbox (everything before "--").
/// (bwrap's --disable-userns would put the command in a nested namespace that cannot be
/// joined; ready() sets the same limit itself.)
fn options(a: *Args, with_net: bool) void {
    a.addAll(&.{ bwrap, "--unshare-user", "--unshare-pid", "--unshare-ipc", "--new-session", "--die-with-parent" });
    if (!with_net) a.add("--unshare-net");
    a.addAll(&.{ "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind", "/tmp", "/tmp" });
    maskTmpSockets(a);
    var rb: [64]u8 = undefined;
    const run_user = std.fmt.bufPrint(&rb, "/run/user/{d}", .{linux.getuid()}) catch "/run/user";
    if (sys.exists(run_user)) a.addAll(&.{ "--tmpfs", a.zs.z(run_user) });
    a.bindIf("--bind", root);
    var pb: [1024]u8 = undefined;
    if (home.len > 0) for (caches) |c| a.bindIf("--bind", std.fmt.bufPrint(&pb, "{s}{s}", .{ home, c }) catch continue);
    var it = std.mem.splitScalar(u8, extra, ':');
    while (it.next()) |e| if (e.len > 0) a.bindIf("--bind", e);
    if (home.len > 0) for (secrets) |c| {
        const p = std.fmt.bufPrint(&pb, "{s}{s}", .{ home, c }) catch continue;
        if (sys.exists(p)) a.addAll(&.{ "--tmpfs", a.zs.z(p) });
    };
    for (sockets) |s| if (sys.exists(s)) a.addAll(&.{ "--ro-bind", "/dev/null", a.zs.z(s) });
    for (guarded) |g| a.bindIf("--ro-bind", std.fmt.bufPrint(&pb, "{s}{s}", .{ root, g }) catch continue);
}

/// Sockets under /tmp (X11, browsers, other agents' daemons) let a command act outside the
/// sandbox. Hide the ones there now, two levels deep; the X11/ICE folders entirely.
fn maskTmpSockets(a: *Args) void {
    for ([_][]const u8{ "/tmp/.X11-unix", "/tmp/.ICE-unix" }) |d| if (sys.exists(d)) a.addAll(&.{ "--tmpfs", a.zs.z(d) });
    scanSockets(a, "/tmp", 1);
}

fn scanSockets(a: *Args, dir: []const u8, depth: u8) void {
    var zb: [1024]u8 = undefined;
    const dfd_rc = linux.open(sys.z(&zb, dir), .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(dfd_rc) != .SUCCESS) return;
    const dfd: i32 = @intCast(dfd_rc);
    defer sys.close(dfd);
    var b: [4096]u8 align(8) = undefined;
    var seen: usize = 0;
    while (seen < 4000) {
        const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch return;
        if (got == 0) return;
        var off: usize = 0;
        while (off < got) : (seen += 1) {
            const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
            const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off + @offsetOf(linux.dirent64, "name")])), 0);
            off += e.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".X11-unix") or std.mem.eql(u8, name, ".ICE-unix")) continue;
            var pb: [1024]u8 = undefined;
            const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name }) catch continue;
            if (e.type == linux.DT.SOCK) {
                a.addAll(&.{ "--ro-bind", "/dev/null", a.zs.z(p) });
            } else if (e.type == linux.DT.DIR and depth > 0) scanSockets(a, p, depth - 1);
        }
    }
}

/// Start the session sandbox unless it is running. null: ready; else why it failed.
pub fn ready() ?[]const u8 {
    if (holder != 0) {
        var status: u32 = 0;
        const rc = linux.wait4(holder, &status, 1, null); // WNOHANG
        if (linux.errno(rc) == .SUCCESS and rc == 0) return null;
        stop();
    }
    const S = struct {
        var a: Args = .{};
        var err: [512]u8 = undefined;
    };
    S.a = .{};
    const a = &S.a;
    options(a, net);
    // "ready" comes from inside, so every mount is in place before the first command joins.
    a.addAll(&.{ "--info-fd", "100", "--", "/bin/sh", "-c", "echo ready; exec /usr/bin/sleep infinity" });
    a.v[a.n] = null;
    var p: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&p, .{ .CLOEXEC = true })) != .SUCCESS) return "pipe failed";
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return "fork failed";
    if (pid_rc == 0) {
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        _ = linux.dup2(@intCast(devnull), 0);
        _ = linux.dup2(p[1], 1);
        _ = linux.dup2(p[1], 2);
        _ = linux.dup2(p[1], 100);
        sys.unblockAll();
        const no_env = [_:null]?[*:0]const u8{};
        _ = linux.execve(bwrap, &a.v, &no_env);
        linux.exit_group(127);
    }
    holder = @intCast(pid_rc);
    sys.close(p[1]);
    holder_out = p[0];
    // bwrap writes {"child-pid": N, ...}, then the holder says "ready"; or bwrap prints an error and exits.
    var b: [1024]u8 = undefined;
    var n: usize = 0;
    while (n < b.len) {
        const r = sys.read(p[0], b[n..]) catch break;
        if (r == 0) break;
        n += r;
        if (std.mem.indexOf(u8, b[0..n], "ready\n") != null) break;
    }
    if (std.mem.indexOf(u8, b[0..n], "ready\n") == null) {
        stop();
        const msg = std.mem.trim(u8, b[0..n], " \r\n");
        return std.fmt.bufPrint(&S.err, "the sandbox did not start: {s}", .{if (msg.len > 0) msg[0..@min(msg.len, 300)] else "bwrap exited"}) catch "the sandbox did not start";
    }
    const key = "\"child-pid\":";
    const at = std.mem.indexOf(u8, b[0..n], key) orelse {
        stop();
        const msg = std.mem.trim(u8, b[0..n], " \r\n");
        return std.fmt.bufPrint(&S.err, "the sandbox did not start: {s}", .{if (msg.len > 0) msg else "bwrap exited"}) catch "the sandbox did not start";
    };
    const digits = std.mem.trim(u8, b[at + key.len ..][0..@min(16, n - at - key.len)], " ,}\n");
    const end = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
    const child = std.fmt.parseInt(u32, digits[0..end], 10) catch {
        stop();
        return "the sandbox did not start: no pid";
    };
    const pfd_rc = linux.pidfd_open(@intCast(child), 0);
    if (linux.errno(pfd_rc) != .SUCCESS) {
        stop();
        return "the sandbox did not start: pidfd_open failed";
    }
    pidfd = @intCast(pfd_rc);
    if (!noNestedUserns()) {
        stop();
        return "the sandbox did not start: cannot turn off user namespaces inside it";
    }
    return null;
}

/// No user namespaces inside the sandbox (`unshare -Ur` was how a model got around a refused
/// mount). Set from a child that holds the sandbox's capabilities; commands hold none.
fn noNestedUserns() bool {
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) return false;
    if (pid_rc == 0) {
        if (linux.errno(linux.setns(pidfd, linux.CLONE.NEWUSER | linux.CLONE.NEWNS)) != .SUCCESS) linux.exit_group(1);
        const fd = sys.open("/proc/sys/user/max_user_namespaces", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0) catch linux.exit_group(1);
        sys.writeAll(fd, "0") catch linux.exit_group(1);
        linux.exit_group(0);
    }
    var status: u32 = 0;
    while (linux.errno(linux.wait4(@intCast(pid_rc), &status, 0, null)) == .INTR) {}
    return status == 0;
}

/// End the session sandbox (everything in it dies with it).
pub fn stop() void {
    if (pidfd >= 0) sys.close(pidfd);
    pidfd = -1;
    if (holder_out >= 0) sys.close(holder_out);
    holder_out = -1;
    if (holder != 0) {
        _ = linux.kill(holder, .KILL);
        var status: u32 = 0;
        _ = linux.wait4(holder, &status, 0, null);
    }
    holder = 0;
}

/// In a forked child: run argv inside the session sandbox (after ready()). Never returns.
/// The child stays outside as the waiter, so the caller's process group and timeouts work;
/// the command runs as its grandchild. With `pid_fd`, the command leads its own process
/// group and writes its pid as seen inside the sandbox there (for `kill -- -PID`).
pub fn execIn(argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8, pid_fd: i32) noreturn {
    _ = linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0); // nothing in the sandbox may ptrace us while we hold its capabilities
    const e = linux.errno(linux.setns(pidfd, all_ns));
    if (e != .SUCCESS) {
        var eb: [96]u8 = undefined;
        sys.writeAll(2, std.fmt.bufPrint(&eb, "awl: could not enter the sandbox ({s})\n", .{@tagName(e)}) catch "awl: could not enter the sandbox\n") catch {};
        linux.exit_group(126);
    }
    const pid_rc = linux.fork();
    if (linux.errno(pid_rc) != .SUCCESS) linux.exit_group(126);
    if (pid_rc == 0) {
        if (pid_fd >= 0) {
            _ = linux.setpgid(0, 0);
            var nb: [16]u8 = undefined;
            sys.writeAll(pid_fd, std.fmt.bufPrint(&nb, "{d}", .{linux.getpid()}) catch "") catch {};
            sys.close(pid_fd);
        }
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(linux.SIG.KILL), 0, 0, 0);
        _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
        if (linux.errno(linux.chdir(cwd)) != .SUCCESS) _ = linux.chdir(@ptrCast(root_z()));
        // exec as our own uid (not 0) drops the capabilities setns gave us
        _ = linux.execve(argv[0].?, argv, env);
        linux.exit_group(127);
    }
    if (pid_fd >= 0) sys.close(pid_fd);
    for ([_]i32{ 0, 1, 2 }) |fd| sys.close(fd);
    var status: u32 = 0;
    while (linux.errno(linux.wait4(@intCast(pid_rc), &status, 0, null)) == .INTR) {}
    linux.exit_group(@intCast(if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f)));
}

/// In a forked child: run argv in a sandbox of its own that keeps the host network (one
/// command the user approved). Same rules otherwise; it does not see the session's
/// localhost or processes. Never returns.
pub fn execOnline(argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8) noreturn {
    const S = struct {
        var a: Args = .{};
    };
    const a = &S.a;
    options(a, true);
    a.addAll(&.{ "--disable-userns", "--chdir", cwd, "--" });
    var i: usize = 0;
    while (argv[i]) |s| : (i += 1) a.add(s);
    a.v[a.n] = null;
    _ = linux.execve(bwrap, &a.v, env);
    linux.exit_group(127);
}

fn root_z() [*:0]const u8 {
    const S = struct {
        var b: [4097]u8 = undefined;
    };
    return sys.z(&S.b, if (root.len > 0) root else "/").ptr;
}

// ---- environment ----

const env_exact = [_][]const u8{ "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "COLORTERM", "NO_COLOR", "LANG", "LANGUAGE", "TZ", "TMPDIR", "EDITOR", "VISUAL", "PAGER", "HOSTNAME", "CI", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_DATA_DIRS", "XDG_CONFIG_DIRS", "GOPATH", "GOROOT", "GOBIN", "GOFLAGS", "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "JAVA_HOME", "VIRTUAL_ENV", "CONDA_PREFIX", "PYTHONPATH", "NODE_PATH", "NVM_DIR", "PNPM_HOME", "BUN_INSTALL", "DENO_DIR", "CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "PKG_CONFIG_PATH", "LD_LIBRARY_PATH", "MAKEFLAGS", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR" };
const env_prefix = [_][]const u8{ "LC_", "MISE_", "__MISE_", "ASDF_" };
const env_deny = [_][]const u8{ "TOKEN", "KEY", "SECRET", "PASS", "AUTH", "CRED", "COOKIE", "SESSION" };

/// May the model's commands see this variable? Allowlisted names, and none that look like secrets.
pub fn envOk(name: []const u8) bool {
    var ub: [128]u8 = undefined;
    if (name.len > ub.len) return false;
    const up = std.ascii.upperString(&ub, name);
    for (env_deny) |d| if (std.mem.indexOf(u8, up, d) != null) return false;
    for (env_exact) |e| if (std.mem.eql(u8, name, e)) return true;
    for (env_prefix) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// The model's commands get only allowlisted variables (see envOk).
pub fn envp(src: []const [*:0]const u8, buf: []?[*:0]const u8) [*:null]const ?[*:0]const u8 {
    var n: usize = 0;
    for (src) |e| {
        if (n + 1 >= buf.len) break;
        const s = std.mem.span(e);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        if (!envOk(s[0..eq])) continue;
        buf[n] = e;
        n += 1;
    }
    buf[n] = null;
    return @ptrCast(buf.ptr);
}

/// Small arena for NUL-terminated strings.
pub const ZStrings = struct {
    b: [32768]u8 = undefined,
    n: usize = 0,
    pub fn z(self: *ZStrings, s: []const u8) [*:0]const u8 {
        if (self.n + s.len + 1 > self.b.len) return "/nonexistent";
        const start = self.n;
        @memcpy(self.b[start .. start + s.len], s);
        self.b[start + s.len] = 0;
        self.n += s.len + 1;
        return @ptrCast(self.b[start..].ptr);
    }
};

// ---- path rules for read/write/edit (in-process) ----

/// `abs` with symlinks resolved as far as the path exists (the rest appended as is).
/// A dangling symlink resolves to "/nonexistent" so nothing writes through it.
pub fn resolve(abs: []const u8, out: []u8) []const u8 {
    var cut = abs.len;
    while (true) {
        const head = if (cut == 0) "/" else abs[0..cut];
        if (sys.open(head, .{ .PATH = true, .CLOEXEC = true }, 0)) |fd| {
            defer sys.close(fd);
            var lb: [64]u8 = undefined;
            const link = std.fmt.bufPrint(&lb, "/proc/self/fd/{d}", .{fd}) catch unreachable;
            var zb: [64]u8 = undefined;
            const rc = linux.readlink(sys.z(&zb, link), out.ptr, out.len);
            if (linux.errno(rc) != .SUCCESS) return abs;
            var n: usize = rc;
            const rest = abs[cut..];
            if (n == 1 and rest.len > 0) n = 0; // "/" + "/rest"
            if (n + rest.len > out.len) return abs;
            @memcpy(out[n .. n + rest.len], rest);
            return out[0 .. n + rest.len];
        } else |_| {}
        if (cut == 0) return abs;
        if (cut == abs.len) { // the leaf is missing: is it a dangling symlink?
            var zb: [4096]u8 = undefined;
            var tb: [8]u8 = undefined;
            if (linux.errno(linux.readlink(sys.z(&zb, abs), &tb, tb.len)) == .SUCCESS) return "/nonexistent";
        }
        cut = std.mem.lastIndexOfScalar(u8, abs[0..cut], '/') orelse 0;
    }
}

/// write/edit: may the model write this path? `abs` is absolute with no ".." (see normalize);
/// symlinks are resolved here. Always yes when the sandbox is off.
pub fn writable(abs: []const u8) bool {
    if (!enforce) return true;
    var rb: [4096]u8 = undefined;
    const p = resolve(abs, &rb);
    if (under(p, root) or under(p, "/tmp")) return true;
    var pb: [1024]u8 = undefined;
    for (caches) |c| if (std.fmt.bufPrint(&pb, "{s}{s}", .{ home, c }) catch null) |hp| if (home.len > 0 and under(p, hp)) return true;
    var it = std.mem.splitScalar(u8, extra, ':');
    while (it.next()) |e| if (e.len > 0 and under(p, e)) return true;
    return false;
}

/// write/edit to this path needs the user's yes every time: the project's .git, AGENTS.md, .agents.
pub fn guardedPath(abs: []const u8) bool {
    if (!enforce or root.len == 0) return false;
    var rb: [4096]u8 = undefined;
    const p = resolve(abs, &rb);
    var pb: [4200]u8 = undefined;
    for ([_][]const u8{ "/.git", "/AGENTS.md", "/.agents" }) |g|
        if (under(p, std.fmt.bufPrint(&pb, "{s}{s}", .{ root, g }) catch continue)) return true;
    return false;
}

/// read: hidden from the model? Secrets, other processes (/proc), the user's sockets (/run/user).
pub fn hidden(abs: []const u8) bool {
    if (!enforce) return false;
    var rb: [4096]u8 = undefined;
    const p = resolve(abs, &rb);
    if (under(p, "/proc") or under(p, "/run/user")) return true;
    var pb: [1024]u8 = undefined;
    if (home.len > 0) for (secrets) |c| if (under(p, std.fmt.bufPrint(&pb, "{s}{s}", .{ home, c }) catch continue)) return true;
    return false;
}

fn under(p: []const u8, dir: []const u8) bool {
    if (dir.len == 0 or !std.mem.startsWith(u8, p, dir)) return false;
    return p.len == dir.len or p[dir.len] == '/' or std.mem.endsWith(u8, dir, "/");
}

/// `path` made absolute against `cwd`, with "." and ".." segments resolved (no symlinks followed).
pub fn normalize(path: []const u8, cwd: []const u8, out: []u8) []const u8 {
    var stack: [256][]const u8 = undefined;
    var n: usize = 0;
    const parts = [_][]const u8{ if (path.len > 0 and path[0] == '/') "" else cwd, path };
    for (parts) |part| {
        var it = std.mem.splitScalar(u8, part, '/');
        while (it.next()) |s| {
            if (s.len == 0 or std.mem.eql(u8, s, ".")) continue;
            if (std.mem.eql(u8, s, "..")) {
                n -|= 1;
                continue;
            }
            if (n < stack.len) {
                stack[n] = s;
                n += 1;
            }
        }
    }
    var len: usize = 0;
    for (stack[0..n]) |s| {
        if (len + 1 + s.len > out.len) break;
        out[len] = '/';
        @memcpy(out[len + 1 .. len + 1 + s.len], s);
        len += 1 + s.len;
    }
    if (len == 0 and out.len > 0) {
        out[0] = '/';
        len = 1;
    }
    return out[0..len];
}

const t = std.testing;

test "sandbox: write rule and path normalization" {
    var nb: [256]u8 = undefined;
    try t.expectEqualStrings("/p/a/c", normalize("../a/./b/../c", "/p/x", &nb));
    try t.expectEqualStrings("/etc/passwd", normalize("/tmp/../etc/passwd", "/p", &nb));
    enforce = true;
    defer enforce = false;
    root = "/home/u/proj";
    home = "/home/u";
    extra = "";
    try t.expect(writable("/home/u/proj/src/a.zig"));
    try t.expect(writable("/home/u/proj"));
    try t.expect(writable("/tmp/x"));
    try t.expect(writable("/home/u/.cache/zig/x"));
    try t.expect(!writable("/home/u/proj2/a"));
    try t.expect(!writable("/home/u/.bashrc"));
    try t.expect(!writable("/etc/passwd"));
    try t.expect(guardedPath("/home/u/proj/.git/config"));
    try t.expect(guardedPath("/home/u/proj/AGENTS.md"));
    try t.expect(guardedPath("/home/u/proj/.agents/skills/x/SKILL.md"));
    try t.expect(!guardedPath("/home/u/proj/src/AGENTS.md.bak"));
    try t.expect(hidden("/home/u/.ssh/id_ed25519"));
    try t.expect(hidden("/proc/1/environ"));
    try t.expect(!hidden("/home/u/proj/a"));
}

test "sandbox: environment allowlist" {
    try t.expect(envOk("PATH"));
    try t.expect(envOk("LC_ALL"));
    try t.expect(envOk("MISE_SHELL"));
    try t.expect(!envOk("GITHUB_TOKEN"));
    try t.expect(!envOk("MISE_GITHUB_TOKEN"));
    try t.expect(!envOk("OPENAI_API_KEY"));
    try t.expect(!envOk("DBUS_SESSION_BUS_ADDRESS"));
    try t.expect(!envOk("SSH_AUTH_SOCK"));
    try t.expect(!envOk("AWL_KEY"));
}

test "sandbox: symlinks resolve before the rule" {
    var wb: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&wb, "/tmp/awl-sbx-test-{d}", .{linux.getpid()}) catch unreachable;
    var zb: [300]u8 = undefined;
    _ = linux.mkdir(sys.z(&zb, dir), 0o700);
    defer {
        var cb: [300]u8 = undefined;
        for ([_][]const u8{ "out", "dangling" }) |f| _ = linux.unlink(sys.z(&cb, std.fmt.bufPrint(&wb, "/tmp/awl-sbx-test-{d}/{s}", .{ linux.getpid(), f }) catch unreachable));
        _ = linux.rmdir(sys.z(&cb, std.fmt.bufPrint(&wb, "/tmp/awl-sbx-test-{d}", .{linux.getpid()}) catch unreachable));
    }
    var lb: [300]u8 = undefined;
    var db: [300]u8 = undefined;
    _ = linux.symlink("/etc/passwd", sys.z(&lb, std.fmt.bufPrint(&db, "{s}/out", .{dir}) catch unreachable));
    _ = linux.symlink("/etc/awl-nope", sys.z(&lb, std.fmt.bufPrint(&db, "{s}/dangling", .{dir}) catch unreachable));
    enforce = true;
    defer enforce = false;
    root = "/nonexistent-root";
    home = "";
    extra = "";
    var pb: [300]u8 = undefined;
    try t.expect(!writable(std.fmt.bufPrint(&pb, "{s}/out", .{dir}) catch unreachable));
    try t.expect(!writable(std.fmt.bufPrint(&pb, "{s}/dangling", .{dir}) catch unreachable));
    try t.expect(writable(std.fmt.bufPrint(&pb, "{s}/new/file", .{dir}) catch unreachable));
}
