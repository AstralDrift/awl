const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Default ReleaseSmall") orelse .ReleaseSmall;
    const release = optimize != .Debug;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = release,
        .single_threaded = true,
        .link_libc = false,
    });
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
    b.step("check", "Assert size / RSS / startup budgets").dependOn(&check.step);

    const e2e = b.addSystemCommand(&.{ "bash", "tests/e2e.sh" });
    e2e.addArtifactArg(exe);
    b.step("e2e", "End-to-end tests against tests/fake_sse.py").dependOn(&e2e.step);
}
