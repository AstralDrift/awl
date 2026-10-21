#!/bin/sh
cat > build.zig <<'Z'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/wordfreq.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run.step);
}
Z
python3 - <<'P'
p = "src/wordfreq.zig"
s = open(p).read()
for a, b in [
    ("var keys = std.ArrayList([]u8).init(alloc);", "var keys: std.ArrayList([]u8) = .empty;"),
    ("keys.deinit();", "keys.deinit(alloc);"),
    ("std.mem.tokenize(u8,", "std.mem.tokenizeAny(u8,"),
    ("try keys.append(w);", "try keys.append(alloc, w);"),
    ("var all = std.ArrayList(Entry).init(alloc);", "var all: std.ArrayList(Entry) = .empty;"),
    ("defer all.deinit();", "defer all.deinit(alloc);"),
    ("try all.append(.{", "try all.append(alloc, .{"),
    ("std.sort.sort(Entry,", "std.mem.sort(Entry,"),
    ("std.math.min(k,", "@min(k,"),
    ("var out = try", "const out = try"),
    ("for (all.items[0..n]) |e, i|", "for (all.items[0..n], 0..) |e, i|"),
]:
    assert a in s, a
    s = s.replace(a, b)
open(p, "w").write(s)
P
