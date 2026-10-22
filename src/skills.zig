//! Agent Skills: list each SKILL.md's name and description in the system prompt.
//! The model reads the full file with the read tool only when a task matches,
//! so a skill costs ~40 tokens until it is used. Same folders as pi:
//! ~/.agents/skills/<name>/SKILL.md and <project>/.agents/skills/<name>/SKILL.md.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const bufm = @import("buf.zig");
const Buf = bufm.Buf;

const max_skills = 32;
const max_desc = 160;

pub const Meta = struct { name: []const u8, desc: []const u8 };

/// Parse `name` and `description` from YAML frontmatter. A skill marked
/// `disable-model-invocation: true` is for the user to invoke and yields null. Handles inline values (quoted or
/// not) and folded/literal blocks (`>`, `>-`, `|`) whose lines are indented. The folded
/// description is joined into `out` with single spaces.
pub fn parse(text: []const u8, out: []u8) ?Meta {
    if (!std.mem.startsWith(u8, text, "---")) return null;
    var it = std.mem.splitScalar(u8, text[3..], '\n');
    _ = it.next(); // rest of the opening --- line
    var name: []const u8 = "";
    var n: usize = 0;
    var in_block = false;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "---")) break;
        if (in_block) {
            if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
                n = join(out, n, std.mem.trim(u8, line, " \t"));
                continue;
            }
            in_block = false;
        }
        if (std.mem.startsWith(u8, line, "disable-model-invocation:")) {
            if (std.mem.eql(u8, std.mem.trim(u8, line[25..], " \t\"'"), "true")) return null;
        } else if (std.mem.startsWith(u8, line, "name:")) {
            name = unquote(std.mem.trim(u8, line[5..], " \t"));
        } else if (std.mem.startsWith(u8, line, "description:")) {
            const v = std.mem.trim(u8, line[12..], " \t");
            if (v.len == 0 or v[0] == '>' or v[0] == '|') {
                in_block = true;
            } else n = join(out, n, unquote(v));
        }
    }
    if (name.len == 0 or n == 0) return null;
    return .{ .name = name, .desc = out[0..n] };
}

fn unquote(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) return v[1 .. v.len - 1];
    return v;
}

fn join(out: []u8, n0: usize, s: []const u8) usize {
    var n = n0;
    if (n > 0 and n < out.len) {
        out[n] = ' ';
        n += 1;
    }
    const k = @min(s.len, out.len - n);
    @memcpy(out[n .. n + k], s[0..k]);
    return n + k;
}

/// Append a "# Skills" section for every skill found in `dirs` (missing dirs are skipped).
pub fn add(head: *Buf, dirs: []const []const u8) void {
    var count: usize = 0;
    for (dirs) |dir| {
        if (dir.len == 0) continue;
        const dfd = sys.open(dir, .{ .DIRECTORY = true, .CLOEXEC = true }, 0) catch continue;
        defer sys.close(dfd);
        var b: [8192]u8 align(8) = undefined;
        var listed_dir = false;
        while (count < max_skills) {
            const got = sys.check(linux.getdents64(dfd, &b, b.len)) catch break;
            if (got == 0) break;
            var off: usize = 0;
            while (off < got and count < max_skills) {
                const e: *align(1) linux.dirent64 = @ptrCast(&b[off]);
                off += e.reclen;
                const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&b[off - e.reclen + @offsetOf(linux.dirent64, "name")])), 0);
                if (name.len == 0 or name[0] == '.') continue;
                var pb: [1024]u8 = undefined;
                const path = std.fmt.bufPrint(&pb, "{s}/{s}/SKILL.md", .{ dir, name }) catch continue;
                var fb: [4096]u8 = undefined; // the frontmatter sits at the top
                const text = sys.readFile(path, &fb) catch continue;
                var db: [1024]u8 = undefined;
                const m = parse(text, &db) orelse continue;
                if (count == 0) bufm.escape(head, "\n\n# Skills\nWhen a task matches a skill below, read its SKILL.md with the read tool before you start, then follow it.");
                var lb: [1600]u8 = undefined;
                if (!listed_dir) {
                    bufm.escape(head, std.fmt.bufPrint(&lb, "\nIn {s}/<name>/SKILL.md:", .{dir}) catch continue);
                    listed_dir = true;
                }
                const desc = cut(m.desc, max_desc);
                bufm.escape(head, std.fmt.bufPrint(&lb, "\n- {s}: {s}{s}", .{ m.name, desc, if (desc.len < m.desc.len) "…" else "" }) catch continue);
                count += 1;
            }
        }
    }
}

fn cut(s: []const u8, w: usize) []const u8 {
    if (s.len <= w) return s;
    var n = w;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

const t = std.testing;

test "skill frontmatter: inline, quoted and folded descriptions" {
    var b: [256]u8 = undefined;
    const a = parse("---\nname: tdd\ndescription: \"Write the failing test first.\"\n---\n# body\n", &b).?;
    try t.expectEqualStrings("tdd", a.name);
    try t.expectEqualStrings("Write the failing test first.", a.desc);
    var b2: [256]u8 = undefined;
    const f = parse("---\nname: omarchy\ndescription: >\n  REQUIRED for desktop config.\n  Use when editing ~/.config/hypr/.\nicon: x\n---\nbody", &b2).?;
    try t.expectEqualStrings("omarchy", f.name);
    try t.expectEqualStrings("REQUIRED for desktop config. Use when editing ~/.config/hypr/.", f.desc);
    var b3: [256]u8 = undefined;
    try t.expect(parse("no frontmatter here", &b3) == null);
    try t.expect(parse("---\nname: x\n---\n", &b3) == null); // no description
    // user-invoked only (Agent Skills spec): never listed for the model
    try t.expect(parse("---\nname: tdd\ndescription: x\ndisable-model-invocation: true\n---\n", &b3) == null);
    try t.expect(parse("---\nname: tdd\ndescription: x\ndisable-model-invocation: false\n---\n", &b3) != null);
}
