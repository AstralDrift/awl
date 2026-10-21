const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/wordfreq.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run.step);
}
