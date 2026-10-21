const std = @import("std");
const sys = @import("sys.zig");

pub const version = "0.1.0";

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.envp = @ptrCast(init.environ.block.slice);
    const argv = init.args.vector;
    if (argv.len > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "--version")) {
        sys.writeAll(sys.stdout, "awl " ++ version ++ "\n") catch {};
        return 0;
    }
    if (argv.len > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "--idle-rss")) {
        var b: [64]u8 = undefined;
        sys.writeAll(sys.stdout, std.fmt.bufPrint(&b, "{d}\n", .{sys.peakRssKb()}) catch "0\n") catch {};
        return 0;
    }
    return 0;
}

test {
    _ = @import("buf.zig");
}
