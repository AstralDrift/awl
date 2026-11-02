const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize_arg = b.option(std.builtin.OptimizeMode, "optimize", "Default ReleaseSmall (Debug for `zig build test`)");
    const optimize = optimize_arg orelse .ReleaseSmall;
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

    // zig build release: the published binaries. Baseline CPU and ReleaseSmall whatever
    // -Dtarget/-Dcpu/-Doptimize say, so the bytes depend only on the source and the Zig
    // version (scripts/release.sh pins it). zig-out/release/awl-linux-{x86_64,aarch64}.
    const rel = b.step("release", "Reproducible release binaries in zig-out/release (see scripts/release.sh)");
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const rel_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .cpu_model = .baseline }),
            .optimize = .ReleaseSmall,
            .strip = true,
            .single_threaded = true,
            .link_libc = false,
        });
        rel_mod.addOptions("build_options", opts);
        const rel_exe = b.addExecutable(.{ .name = "awl", .root_module = rel_mod });
        rel.dependOn(&b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = b.fmt("awl-linux-{s}", .{@tagName(arch)}),
        }).step);
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run awl").dependOn(&run.step);

    // Unit tests build in Debug unless -Doptimize says otherwise: ReleaseSmall turns off the
    // overflow, bounds and `unreachable` checks, so a bug a test hits would pass silently.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize_arg orelse .Debug,
        .single_threaded = true,
        .link_libc = false,
    });
    test_mod.addOptions("build_options", opts);
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Unit tests (Debug: runtime safety checks on)").dependOn(&b.addRunArtifact(tests).step);

    const lint = b.addSystemCommand(&.{ "sh", "tests/lint.sh", b.graph.zig_exe });
    b.step("lint", "zig fmt, project rules, LOG promises, commit figures, shellcheck, ruff, actionlint (tests/lint.sh)").dependOn(&lint.step);

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
