const std = @import("std");
const wf = @import("wordfreq.zig");

test "hidden: ties alphabetical, k larger than vocabulary, no leaks" {
    const a = std.testing.allocator;
    const got = try wf.topWords(a, "b a c b a (c) d", 10);
    defer wf.freeEntries(a, got);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    const want = [_][]const u8{ "a", "b", "c", "d" };
    const cnt = [_]usize{ 2, 2, 2, 1 };
    for (got, 0..) |e, i| {
        try std.testing.expectEqualStrings(want[i], e.word);
        try std.testing.expectEqual(cnt[i], e.count);
    }
}

test "hidden: case folding and k = 0" {
    const a = std.testing.allocator;
    const one = try wf.topWords(a, "Zig ZIG zig zag", 1);
    defer wf.freeEntries(a, one);
    try std.testing.expectEqualStrings("zig", one[0].word);
    try std.testing.expectEqual(@as(usize, 3), one[0].count);
    const none = try wf.topWords(a, "x y", 0);
    defer wf.freeEntries(a, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
