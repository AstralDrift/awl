//! Integers for std.json structs without its float fallback. std.json parses an int
//! field through parseFloat(f128) when the text is not a plain integer, which links
//! ~19 KB of soft-float code. Int(T) accepts 12, "12" and 12.0 / 12.00 (models write
//! all three) with integer code only.
const std = @import("std");

pub fn Int(comptime T: type) type {
    return struct {
        v: T,

        pub fn jsonParse(a: std.mem.Allocator, source: anytype, o: std.json.ParseOptions) !@This() {
            const tok = try source.nextAllocMax(a, .alloc_if_needed, o.max_value_len.?);
            const s = switch (tok) {
                inline .number, .allocated_number, .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            return .{ .v = parse(s) orelse return error.InvalidNumber };
        }

        pub fn parse(s0: []const u8) ?T {
            var s = std.mem.trim(u8, s0, " ");
            if (std.mem.indexOfScalar(u8, s, '.')) |dot| { // 12.0 -> 12; 12.5 is not an integer
                for (s[dot + 1 ..]) |c| if (c != '0') return null;
                s = s[0..dot];
            }
            return std.fmt.parseInt(T, s, 10) catch null;
        }
    };
}

/// A JSON string field. std.json would also accept an array of byte numbers for a
/// []const u8, which instantiates its integer parser and with it the f128 fallback.
pub const Str = struct {
    v: []const u8,

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, o: std.json.ParseOptions) !Str {
        const tok = try source.nextAllocMax(a, .alloc_if_needed, o.max_value_len.?);
        return switch (tok) {
            inline .string, .allocated_string => |s| .{ .v = s },
            else => error.UnexpectedToken,
        };
    }
};

pub const empty = Str{ .v = "" };

test "Int: plain, quoted and .0 numbers; fractions refused" {
    const I = Int(u32);
    try std.testing.expectEqual(@as(?u32, 12), I.parse("12"));
    try std.testing.expectEqual(@as(?u32, 12), I.parse("12.00"));
    try std.testing.expectEqual(@as(?u32, null), I.parse("12.5"));
    try std.testing.expectEqual(@as(?u32, null), I.parse("-1"));
    var b: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&b);
    const S = struct { n: Int(u32), m: ?Int(u8) = null };
    const r = try std.json.parseFromSliceLeaky(S, fba.allocator(), "{\"n\":\"7\",\"m\":3.0}", .{});
    try std.testing.expectEqual(@as(u32, 7), r.n.v);
    try std.testing.expectEqual(@as(u8, 3), r.m.?.v);
}

test "Str: strings only" {
    var b: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&b);
    const S = struct { a: Str, b: ?Str = null, c: Str = empty };
    const r = try std.json.parseFromSliceLeaky(S, fba.allocator(), "{\"a\":\"x\\ny\"}", .{});
    try std.testing.expectEqualStrings("x\ny", r.a.v);
    try std.testing.expect(r.b == null);
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(S, fba.allocator(), "{\"a\":[1,2]}", .{}));
}
