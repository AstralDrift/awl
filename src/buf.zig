//! A growable byte buffer backed by one reserved virtual region.
//! It never reallocates or copies: pages become resident only when touched,
//! so RSS tracks what is actually used. `reset` hands the pages back.
const std = @import("std");
const linux = std.os.linux;

pub const Buf = struct {
    base: ?[*]u8 = null,
    len: usize = 0,
    cap: usize,

    pub fn init(cap: usize) Buf {
        return .{ .cap = std.mem.alignForward(usize, cap, std.heap.pageSize()) };
    }

    fn reserve(self: *Buf) void {
        const rc = linux.mmap(null, self.cap, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        if (linux.errno(rc) != .SUCCESS) @panic("mmap");
        self.base = @ptrFromInt(rc);
    }

    pub fn items(self: *const Buf) []u8 {
        const b = self.base orelse return &.{};
        return b[0..self.len];
    }

    /// Grow by n bytes and return the new tail. Truncates silently at capacity.
    pub fn extend(self: *Buf, n: usize) []u8 {
        if (self.base == null) self.reserve();
        const k = @min(n, self.cap - self.len);
        const out = self.base.?[self.len .. self.len + k];
        self.len += k;
        return out;
    }

    pub fn add(self: *Buf, s: []const u8) void {
        const dst = self.extend(s.len);
        @memcpy(dst, s[0..dst.len]);
    }

    pub fn byte(self: *Buf, c: u8) void {
        self.add(&[_]u8{c});
    }

    pub fn print(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        self.add(std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..0]);
    }

    pub fn full(self: *const Buf) bool {
        return self.len == self.cap;
    }

    /// Drop contents. Pages past `keep` bytes are returned to the kernel.
    pub fn reset(self: *Buf) void {
        self.truncate(0);
    }

    pub fn truncate(self: *Buf, n: usize) void {
        if (n >= self.len) return;
        const keep: usize = 64 * 1024;
        if (self.base) |b| {
            const from = std.mem.alignForward(usize, @max(n, keep), std.heap.pageSize());
            const to = std.mem.alignForward(usize, self.len, std.heap.pageSize());
            if (to > from) _ = linux.madvise(b + from, to - from, linux.MADV.DONTNEED);
        }
        self.len = n;
    }
};

/// JSON string escaping with UTF-8 repair (invalid bytes become U+FFFD).
pub fn escape(out: *Buf, s: []const u8) void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => out.add("\\\""),
                '\\' => out.add("\\\\"),
                '\n' => out.add("\\n"),
                '\r' => out.add("\\r"),
                '\t' => out.add("\\t"),
                0...8, 11, 12, 14...0x1f, 0x7f => out.print("\\u{x:0>4}", .{c}),
                else => out.byte(c),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (n != 0 and i + n <= s.len) {
            if (std.unicode.utf8Decode(s[i .. i + n])) |_| {
                out.add(s[i .. i + n]);
                i += n;
                continue;
            } else |_| {}
        }
        out.add("\u{FFFD}");
        i += 1;
    }
}

/// Write `"s"` as a JSON string literal.
pub fn str(out: *Buf, s: []const u8) void {
    out.byte('"');
    escape(out, s);
    out.byte('"');
}

test "escape" {
    var b = Buf.init(4096);
    str(&b, "a\"b\\\n\x01\xff\xe2\x82\xac");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\\\n\\u0001\u{FFFD}\u{20AC}\"", b.items());
}

test "truncate keeps content below n" {
    var b = Buf.init(1 << 20);
    var big: [200 * 1024]u8 = undefined;
    @memset(&big, 'x');
    b.add(&big);
    b.truncate(10);
    try std.testing.expectEqual(@as(usize, 10), b.len);
    b.add("yz");
    try std.testing.expectEqualStrings("xxxxxxxxxxyz", b.items());
}
