//! Interactive prompt. (Phase 6 replaces this plain line reader with the raw-mode editor.)
const std = @import("std");
const sys = @import("sys.zig");
const agent = @import("agent.zig");

pub fn repl() u8 {
    var line: [65536]u8 = undefined;
    while (true) {
        sys.writeAll(sys.stdout, "> ") catch {};
        const n = sys.read(sys.stdin, &line) catch return 1;
        if (n == 0) return 0;
        const text = std.mem.trim(u8, line[0..n], " \r\n");
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, "/quit")) return 0;
        agent.user(text);
        _ = agent.run();
    }
}

/// Put the terminal back the way we found it (also called on panic).
pub fn restore() void {}
