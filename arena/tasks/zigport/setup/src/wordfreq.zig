//! Word frequency counting: the k most common words in a text.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    word: []const u8, // owned, lowercased
    count: usize,
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.word, b.word);
}

/// The k most frequent words (ASCII letters only, case-insensitive), most frequent first,
/// ties broken alphabetically. Caller frees with freeEntries.
pub fn topWords(alloc: Allocator, text: []const u8, k: usize) ![]Entry {
    var counts = std.StringHashMap(usize).init(alloc);
    defer counts.deinit();
    var keys = std.ArrayList([]u8).init(alloc);
    defer {
        for (keys.items) |key| alloc.free(key);
        keys.deinit();
    }

    var it = std.mem.tokenize(u8, text, " \t\r\n.,;:!?\"()");
    while (it.next()) |raw| {
        const w = try std.ascii.allocLowerString(alloc, raw);
        const gop = try counts.getOrPut(w);
        if (gop.found_existing) {
            alloc.free(w);
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
            try keys.append(w);
        }
    }

    var all = std.ArrayList(Entry).init(alloc);
    defer all.deinit();
    var ci = counts.iterator();
    while (ci.next()) |e| try all.append(.{ .word = e.key_ptr.*, .count = e.value_ptr.* });
    std.sort.sort(Entry, all.items, {}, lessThan);

    const n = std.math.min(k, all.items.len);
    var out = try alloc.alloc(Entry, n);
    for (all.items[0..n]) |e, i| out[i] = .{ .word = try alloc.dupe(u8, e.word), .count = e.count };
    return out;
}

pub fn freeEntries(alloc: Allocator, entries: []Entry) void {
    for (entries) |e| alloc.free(e.word);
    alloc.free(entries);
}

test "counts and orders" {
    const got = try topWords(std.testing.allocator, "the cat and the hat. The end!", 2);
    defer freeEntries(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("the", got[0].word);
    try std.testing.expectEqual(@as(usize, 3), got[0].count);
    try std.testing.expectEqualStrings("and", got[1].word);
}

test "empty text" {
    const got = try topWords(std.testing.allocator, "  \n ", 5);
    defer freeEntries(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
