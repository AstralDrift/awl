//! Sandbox for the commands the model runs (bash tool, background jobs), with bubblewrap:
//! the whole filesystem read-only, writable only the project (git root or cwd), /tmp, build caches
//! and AWL_SANDBOX_WRITE; secrets and the docker socket hidden; network optional (AWL_SANDBOX_NET=off).
//! write/edit follow the same write rule in-process. AWL_SANDBOX=off turns it all off; without
//! /usr/bin/bwrap it is off and the welcome line says so. The user's own !cmd is never sandboxed.
const std = @import("std");
const sys = @import("sys.zig");

const bwrap = "/usr/bin/bwrap";
pub var on = false;
pub var net = true;
var root_b: [4096]u8 = undefined;
pub var root: []const u8 = "";
var home: []const u8 = "";
var extra_b: [2048]u8 = undefined;
var extra: []const u8 = ""; // AWL_SANDBOX_WRITE, ':'-separated

/// Paths hidden from sandboxed commands (each replaced by an empty tmpfs, or /dev/null for sockets).
const secrets = [_][]const u8{ "/.ssh", "/.gnupg", "/.aws", "/.config/gh", "/.local/state/omarchy", "/.password-store", "/.local/share/keyrings", "/.docker", "/.kube" };
const sockets = [_][]const u8{ "/run/docker.sock", "/var/run/docker.sock" };
const caches = [_][]const u8{ "/.cache", "/.npm", "/.cargo/registry", "/go/pkg" };

pub fn setup(project_root: []const u8) void {
    home = sys.getenv("HOME") orelse "";
    const want = !std.mem.eql(u8, sys.getenv("AWL_SANDBOX") orelse "on", "off");
    on = want and sys.exists(bwrap);
    net = !std.mem.eql(u8, sys.getenv("AWL_SANDBOX_NET") orelse "on", "off");
    const n = @min(project_root.len, root_b.len);
    @memcpy(root_b[0..n], project_root[0..n]);
    root = root_b[0..n];
    if (sys.getenv("AWL_SANDBOX_WRITE")) |w| {
        const m = @min(w.len, extra_b.len);
        @memcpy(extra_b[0..m], w[0..m]);
        extra = extra_b[0..m];
    }
}

/// One line for the welcome screen and the tool description.
pub fn describe(buf: []u8) []const u8 {
    if (!on) return if (std.mem.eql(u8, sys.getenv("AWL_SANDBOX") orelse "on", "off")) "sandbox off" else "sandbox off (no bwrap)";
    return std.fmt.bufPrint(buf, "sandbox: writes only to the project, /tmp and caches; network {s}", .{if (net) "on" else "off"}) catch "sandbox on";
}

/// argv for `bash -c cmd` inside the sandbox, or plain bash when it is off. `zs` holds the
/// NUL-terminated strings built here (paths under HOME); it must outlive the exec.
pub fn argv(cmd: [*:0]const u8, cwd: []const u8, out: *[96:null]?[*:0]const u8, zs: *ZStrings) []const ?[*:0]const u8 {
    var n: usize = 0;
    const add = struct {
        fn f(o: *[96:null]?[*:0]const u8, i: *usize, s: [*:0]const u8) void {
            if (i.* < o.len - 4) {
                o[i.*] = s;
                i.* += 1;
            }
        }
    }.f;
    if (on) {
        for ([_][*:0]const u8{ bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind", "/tmp", "/tmp", "--die-with-parent" }) |s| add(out, &n, s);
        const r = zs.z(root);
        for ([_][*:0]const u8{ "--bind", r, r }) |s| add(out, &n, s);
        for (caches) |c| if (zs.home(home, c)) |p| if (sys.exists(std.mem.span(p))) {
            for ([_][*:0]const u8{ "--bind", p, p }) |s| add(out, &n, s);
        };
        var it = std.mem.splitScalar(u8, extra, ':');
        while (it.next()) |e| if (e.len > 0 and sys.exists(e)) {
            const p = zs.z(e);
            for ([_][*:0]const u8{ "--bind", p, p }) |s| add(out, &n, s);
        };
        for (secrets) |c| if (zs.home(home, c)) |p| if (sys.exists(std.mem.span(p))) {
            for ([_][*:0]const u8{ "--tmpfs", p }) |s| add(out, &n, s);
        };
        for (sockets) |s0| if (sys.exists(s0)) {
            const p = zs.z(s0);
            for ([_][*:0]const u8{ "--ro-bind", "/dev/null", p }) |s| add(out, &n, s);
        };
        if (!net) add(out, &n, "--unshare-net");
        const c = zs.z(cwd);
        for ([_][*:0]const u8{ "--chdir", c, "--" }) |s| add(out, &n, s);
    }
    for ([_][*:0]const u8{ "/bin/bash", "-c", cmd }) |s| add(out, &n, s);
    out[n] = null;
    return out[0..n];
}

/// Small arena for the NUL-terminated paths argv() needs.
pub const ZStrings = struct {
    b: [16384]u8 = undefined,
    n: usize = 0,
    pub fn z(self: *ZStrings, s: []const u8) [*:0]const u8 {
        if (self.n + s.len + 1 > self.b.len) return "/nonexistent";
        const start = self.n;
        @memcpy(self.b[start .. start + s.len], s);
        self.b[start + s.len] = 0;
        self.n += s.len + 1;
        return @ptrCast(self.b[start..].ptr);
    }
    fn home(self: *ZStrings, h: []const u8, rel: []const u8) ?[*:0]const u8 {
        if (h.len == 0) return null;
        var pb: [1024]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}{s}", .{ h, rel }) catch return null;
        return self.z(p);
    }
};

/// write/edit: may the model write this path? (Same rule as the sandbox; always yes when it is off.)
/// `abs` is an absolute path with no ".." left (see normalize).
pub fn writable(abs: []const u8) bool {
    if (!on) return true;
    if (under(abs, root) or under(abs, "/tmp")) return true;
    var pb: [1024]u8 = undefined;
    for (caches) |c| if (std.fmt.bufPrint(&pb, "{s}{s}", .{ home, c }) catch null) |p| if (home.len > 0 and under(abs, p)) return true;
    var it = std.mem.splitScalar(u8, extra, ':');
    while (it.next()) |e| if (e.len > 0 and under(abs, e)) return true;
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
    on = true;
    defer on = false;
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
}
