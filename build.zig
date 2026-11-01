const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Default ReleaseSmall") orelse .ReleaseSmall;
    const release = optimize != .Debug;

    // `awl --version` prints the version from build.zig.zon and the commit it was built from:
    // -Dcommit=<sha>, else `git rev-parse HEAD` when the build root is a checkout's top level,
    // else "unknown" (a source tarball). The full hash is stored and the first 7 printed.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", @import("build.zig.zon").version);
    opts.addOption([]const u8, "commit", b.option([]const u8, "commit", "Commit shown by --version (default: git rev-parse HEAD)") orelse gitCommit(b));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = release,
        .single_threaded = true,
        .link_libc = false,
    });
    mod.addOptions("build_options", opts);
    const exe = b.addExecutable(.{ .name = "awl", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run awl").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Unit tests").dependOn(&b.addRunArtifact(tests).step);

    const check = b.addSystemCommand(&.{ "sh", "tests/check.sh" });
    check.addArtifactArg(exe);
    b.step("check", "Assert RSS / startup budgets").dependOn(&check.step);

    const e2e = b.addSystemCommand(&.{ "bash", "tests/e2e.sh" });
    e2e.addArtifactArg(exe);
    const embed = b.addSystemCommand(&.{ "bash", "tests/embed.sh" });
    embed.addArtifactArg(exe);
    embed.step.dependOn(&e2e.step); // one fake server at a time, readable output
    b.step("e2e", "End-to-end tests against tests/fake_sse.py").dependOn(&embed.step);

    const sbx = b.addSystemCommand(&.{ "bash", "tests/sandbox.sh" });
    sbx.addArtifactArg(exe);
    b.step("sandbox", "Sandbox escape checks against tests/fake_sse.py").dependOn(&sbx.step);
}

fn gitCommit(b: *std.Build) []const u8 {
    var code: u8 = 0;
    // --show-prefix prints an empty line only at the top level: a tarball unpacked inside
    // some other repository must not take that repository's commit.
    const out = b.runAllowFail(&.{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--show-prefix", "HEAD" }, &code, .ignore) catch return "unknown";
    var it = std.mem.splitScalar(u8, out, '\n');
    if ((it.next() orelse return "unknown").len != 0) return "unknown";
    const sha = it.next() orelse return "unknown";
    return if (sha.len == 40) sha else "unknown";
}
