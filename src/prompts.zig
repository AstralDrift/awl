//! Prompt commands: `/NAME args` sends a saved prompt. Files `NAME.md` in
//! `<project>/.agents/prompts/` and `~/.config/awl/prompts/` (the project's win); `$ARGUMENTS`
//! takes everything after the name, `$1`..`$9` its words; with no placeholder the arguments
//! are added at the end. An optional front matter (`---` … `description: …` … `---`) is not
//! sent; its description shows in /help and the command picker. /review and /init are built in
//! (a file with the same name replaces one).
const std = @import("std");
const sys = @import("sys.zig");
const Buf = @import("buf.zig").Buf;

const builtin = [_]struct { name: []const u8, body: []const u8 }{
    .{ .name = "review", .body =
    \\---
    \\description: review the uncommitted changes (reads only)
    \\---
    \\Review the changes in this repository that are not committed yet: run git status and git diff (and git diff --cached), and read new files whole. Look for bugs, security problems, broken behavior for existing callers and missing tests. Report what you find ordered by severity, each with file:line and a one-line fix; say plainly if you find nothing. Do not change any files.
    \\$ARGUMENTS
    },
    .{ .name = "init", .body =
    \\---
    \\description: write an AGENTS.md for this project
    \\---
    \\Create AGENTS.md at the project root for coding agents that work in this repository: how to build, test and run it, the layout of the source, conventions you can see in the code, and anything surprising. Facts only, each checked against the files; under 60 lines. If an AGENTS.md exists, improve it instead.
    \\$ARGUMENTS
    },
};

/// The folders searched, project first. `root`: the project root.
fn dirs(root: []const u8, b1: []u8, b2: []u8) [2][]const u8 {
    const p = std.fmt.bufPrint(b1, "{s}/.agents/prompts", .{root}) catch "";
    const u = if (sys.getenv("XDG_CONFIG_HOME")) |x| (std.fmt.bufPrint(b2, "{s}/awl/prompts", .{x}) catch "") else if (sys.getenv("HOME")) |h| (std.fmt.bufPrint(b2, "{s}/.config/awl/prompts", .{h}) catch "") else "";
    return .{ p, u };
}

/// The text of prompt `name` (file or built in) in `out`; false when there is none.
pub fn load(root: []const u8, name: []const u8, out: *Buf) bool {
    if (name.len == 0 or name.len > 64 or std.mem.indexOfAny(u8, name, "/.") != null) return false;
    var b1: [4200]u8 = undefined;
    var b2: [4200]u8 = undefined;
    for (dirs(root, &b1, &b2)) |d| {
        if (d.len == 0) continue;
        var pb: [4400]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/{s}.md", .{ d, name }) catch continue;
        const f = sys.open(p, .{ .CLOEXEC = true }, 0) catch continue;
        defer sys.close(f);
        while (true) {
            const dst = out.extend(1 << 16);
            const got = sys.read(f, dst) catch 0;
            out.truncate(out.len - (dst.len - got));
            if (got == 0) break;
        }
        return true;
    }
    for (builtin) |bi| if (std.mem.eql(u8, bi.name, name)) {
        out.add(bi.body);
        return true;
    };
    return false;
}

/// The body without its front matter, and the description from it ("" when none).
pub fn split(text: []const u8) struct { body: []const u8, description: []const u8 } {
    if (!std.mem.startsWith(u8, text, "---\n")) return .{ .body = text, .description = "" };
    const end = std.mem.indexOf(u8, text[4..], "\n---") orelse return .{ .body = text, .description = "" };
    const fm = text[4 .. 4 + end];
    var rest = text[4 + end + 4 ..];
    if (std.mem.startsWith(u8, rest, "\n")) rest = rest[1..];
    var desc: []const u8 = "";
    var it = std.mem.splitScalar(u8, fm, '\n');
    while (it.next()) |l| if (std.mem.startsWith(u8, l, "description:")) {
        desc = std.mem.trim(u8, l[12..], " \"'");
    };
    return .{ .body = rest, .description = desc };
}

/// `body` with $ARGUMENTS and $1..$9 filled from `args`; with neither, the arguments are added
/// at the end. Trailing blank lines are dropped.
pub fn expand(body: []const u8, args: []const u8, out: *Buf) void {
    var words: [9][]const u8 = .{""} ** 9;
    var it = std.mem.tokenizeAny(u8, args, " \t\n");
    var nw: usize = 0;
    while (it.next()) |w| : (nw += 1) if (nw < 9) {
        words[nw] = w;
    };
    var used = false;
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '$') {
            if (std.mem.startsWith(u8, body[i..], "$ARGUMENTS")) {
                out.add(args);
                i += 10;
                used = true;
                continue;
            }
            if (i + 1 < body.len and body[i + 1] >= '1' and body[i + 1] <= '9') {
                out.add(words[body[i + 1] - '1']);
                i += 2;
                used = true;
                continue;
            }
        }
        out.byte(body[i]);
        i += 1;
    }
    while (out.len > 0 and (out.items()[out.len - 1] == '\n' or out.items()[out.len - 1] == ' ')) out.truncate(out.len - 1);
    if (!used and args.len > 0) {
        out.add("\n\n");
        out.add(args);
    }
}

/// Every prompt command, "/name\tdescription" per line, project first, no repeats.
pub fn list(root: []const u8, out: *Buf) void {
    var b1: [4200]u8 = undefined;
    var b2: [4200]u8 = undefined;
    for (dirs(root, &b1, &b2)) |d| {
        if (d.len == 0) continue;
        const dfd = sys.open(d, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch continue;
        defer sys.close(dfd);
        var b: [8192]u8 align(8) = undefined;
        while (true) {
            const linux = std.os.linux;
            const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
            if (got == 0) break;
            var off: usize = 0;
            while (off < got) {
                const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
                off += e.reclen;
                const nm = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off - e.reclen + @offsetOf(linux.dirent64, "name")])), 0);
                if (!std.mem.endsWith(u8, nm, ".md") or nm.len < 4) continue;
                add(out, root, nm[0 .. nm.len - 3]);
            }
        }
    }
    for (builtin) |bi| add(out, root, bi.name);
}

fn add(out: *Buf, root: []const u8, name: []const u8) void {
    var lb: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "\n/{s}\t", .{name}) catch return;
    if (std.mem.startsWith(u8, out.items(), line[1..]) or std.mem.indexOf(u8, out.items(), line) != null) return; // seen
    var t = Buf.init(1 << 20);
    defer t.free();
    if (!load(root, name, &t)) return;
    const d = split(t.items()).description;
    out.print("{s}{s}\n", .{ line[1..], d[0..@min(d.len, 80)] });
}

test "expand fills arguments" {
    var b = Buf.init(4096);
    defer b.free();
    expand("fix $1 in $2, then $ARGUMENTS\n\n", "parse lib.zig", &b);
    try std.testing.expectEqualStrings("fix parse in lib.zig, then parse lib.zig", b.items());
    b.reset();
    expand("review this\n", "focus on errors", &b);
    try std.testing.expectEqualStrings("review this\n\nfocus on errors", b.items());
    b.reset();
    expand("cost $5\n$ARGUMENTS\n", "", &b);
    try std.testing.expectEqualStrings("cost", b.items()); // a missing word is empty; trailing space dropped
}

test "front matter gives the description" {
    const s = split("---\ndescription: \"say hi\"\nx: 1\n---\nhello $ARGUMENTS\n");
    try std.testing.expectEqualStrings("say hi", s.description);
    try std.testing.expectEqualStrings("hello $ARGUMENTS\n", s.body);
    try std.testing.expectEqualStrings("plain", split("plain").body);
}
