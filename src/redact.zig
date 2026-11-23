//! Credentials in tool output (issue 43). One pass over the bytes already in the buffer replaces
//! high-confidence credential shapes with a marker, in place, before they reach the model, the
//! session file or its view. On every endpoint: a localhost AWL_URL can be a proxy to a cloud model,
//! and session files stay on disk. AWL_REDACT=off sends tool output as is.
//! Shapes: PEM private key blocks, AWS access key ids, GitHub tokens, sk- API keys (OpenAI, Anthropic,
//! OpenRouter), Slack tokens, JWTs. Each must start a word, so "task-…" or a base64 blob never match.
const std = @import("std");

pub const marker = "[REDACTED]";
pub var on = true;

pub const kinds = [_][]const u8{ "private key", "AWS key", "GitHub token", "API key", "Slack token", "JWT" };

pub const Result = struct {
    len: usize,
    hits: u32 = 0,
    kinds: u8 = 0, // bit k: kinds[k] was found
};

/// Bytes that can start a shape: everything else is copied without a look.
const first = blk: {
    var tab = [_]bool{false} ** 256;
    for ("-Agsxe") |c| tab[c] = true;
    break :blk tab;
};

/// Replace each credential in `b` with `marker`, moving the rest down. Returns the new length
/// (never longer: every shape is at least marker.len bytes). No allocation.
pub fn scan(b: []u8) Result {
    var r = Result{ .len = 0 };
    var w: usize = 0;
    var i: usize = 0;
    // the two bytes before b[i] as they were (b[w..] is being overwritten behind us)
    var p1: u8 = ' ';
    var p2: u8 = ' ';
    while (i < b.len) {
        const c = b[i];
        if (first[c]) {
            const start = !word(p1) or (p2 == '\\' and (p1 == 'n' or p1 == 't' or p1 == 'r')); // \n in JSON text (a resumed session)
            if (match(b, i, start)) |m| {
                p2 = b[i + m.len - 2];
                p1 = b[i + m.len - 1];
                @memcpy(b[w..][0..marker.len], marker);
                w += marker.len;
                i += m.len;
                r.hits += 1;
                r.kinds |= @as(u8, 1) << m.kind;
                continue;
            }
        }
        b[w] = c;
        w += 1;
        i += 1;
        p2 = p1;
        p1 = c;
    }
    r.len = w;
    return r;
}

const Match = struct { len: usize, kind: u3 };

fn match(b: []const u8, i: usize, start: bool) ?Match {
    const s = b[i..];
    if (s[0] == '-') return if (pem(s)) |n| .{ .len = n, .kind = 0 } else null;
    if (!start) return null;
    return switch (s[0]) {
        'A' => if (aws(s)) .{ .len = 20, .kind = 1 } else null,
        'g' => if (github(s)) |n| .{ .len = n, .kind = 2 } else null,
        's' => if (skKey(s)) |n| .{ .len = n, .kind = 3 } else null,
        'x' => if (slack(s)) |n| .{ .len = n, .kind = 4 } else null,
        'e' => if (jwt(s)) |n| .{ .len = n, .kind = 5 } else null,
        else => null,
    };
}

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn b64url(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}
fn run(s: []const u8, from: usize, comptime ok: fn (u8) bool) usize {
    var j = from;
    while (j < s.len and ok(s[j])) j += 1;
    return j - from;
}

/// -----BEGIN … PRIVATE KEY----- through the END line that closes its body. The body is key bytes
/// only (base64, line breaks, JSON's \n, header lines like "DEK-Info: AES-128-CBC,…"): prose or a
/// JSON line's closing quote ends it, so a later -----END elsewhere in the output is never reached.
/// A body cut off before END (truncated output) counts with 32 key bytes or more; a header that is
/// only mentioned is left alone.
fn pem(s: []const u8) ?usize {
    const begin = "-----BEGIN ";
    if (!std.mem.startsWith(u8, s, begin)) return null;
    const head_end = std.mem.indexOfAnyPos(u8, s[0..@min(s.len, 80)], begin.len, "\n\\") orelse @min(s.len, 80);
    const tag = std.mem.indexOf(u8, s[begin.len..head_end], "PRIVATE KEY-----") orelse return null;
    var j = begin.len + tag + "PRIVATE KEY-----".len;
    var key: usize = 0;
    while (j < s.len) : (j += 1) {
        if (s[j] == '-' and std.mem.startsWith(u8, s[j..], "-----END ")) {
            const close = std.mem.indexOfPos(u8, s[0..@min(s.len, j + 80)], j + 9, "-----") orelse return j + 9;
            return close + 5;
        }
        switch (s[j]) {
            'A'...'Z', 'a'...'z', '0'...'9', '+', '/', '=' => key += 1,
            '\n', '\r', ':', ',', '-', '\\' => {},
            ' ' => if (s[j - 1] != ':') break,
            else => break,
        }
    }
    return if (key >= 32) j else null;
}

/// AKIA/ASIA + 16 upper-case letters or digits, then not a word byte.
fn aws(s: []const u8) bool {
    if (s.len < 20 or !(std.mem.startsWith(u8, s, "AKIA") or std.mem.startsWith(u8, s, "ASIA"))) return false;
    for (s[4..20]) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    return s.len == 20 or !word(s[20]);
}

/// ghp_/gho_/ghu_/ghs_/ghr_ + 36 or more, or github_pat_ + 22 or more.
fn github(s: []const u8) ?usize {
    if (std.mem.startsWith(u8, s, "github_pat_")) {
        const n = run(s, 11, word);
        return if (n >= 22) 11 + n else null;
    }
    if (s.len < 4 or s[1] != 'h' or s[3] != '_' or std.mem.indexOfScalar(u8, "pousr", s[2]) == null) return null;
    const n = run(s, 4, std.ascii.isAlphanumeric);
    return if (n >= 36) 4 + n else null;
}

/// sk- + a run with a dash-free stretch of 20 or more holding a digit: sk-proj-…, sk-ant-api03-…,
/// sk-or-v1-<hex>. Kebab-case names ("sk-learn-model-selection") have no such stretch.
fn skKey(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "sk-")) return null;
    const n = run(s, 3, b64url);
    var seg: usize = 0;
    var digit = false;
    for (s[3 .. 3 + n]) |c| {
        if (c == '-') {
            seg = 0;
            digit = false;
            continue;
        }
        seg += 1;
        digit = digit or std.ascii.isDigit(c);
        if (seg >= 20 and digit) return 3 + n;
    }
    return null;
}

/// xoxa-/xoxb-/xoxp-/xoxo-/xoxs-/xoxr- + 10 or more, with a digit.
fn slack(s: []const u8) ?usize {
    if (s.len < 5 or !std.mem.startsWith(u8, s, "xox") or s[4] != '-' or std.mem.indexOfScalar(u8, "abposr", s[3]) == null) return null;
    const n = run(s, 5, b64url);
    if (n < 10 or std.mem.indexOfAny(u8, s[5 .. 5 + n], "0123456789") == null) return null;
    return 5 + n;
}

/// eyJ….eyJ….… : header and payload are base64url JSON objects, then a signature.
fn jwt(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "eyJ")) return null;
    const a = run(s, 0, b64url);
    if (a < 10 or a + 4 > s.len or s[a] != '.' or !std.mem.startsWith(u8, s[a + 1 ..], "eyJ")) return null;
    const b = run(s, a + 1, b64url);
    if (b < 10 or a + 1 + b >= s.len or s[a + 1 + b] != '.') return null;
    const c = run(s, a + 2 + b, b64url);
    if (c < 10) return null;
    return a + 2 + b + c;
}

/// "private key, AWS key" for the kinds in `k`.
pub fn names(k: u8, out: []u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    var n: usize = 0;
    for (kinds, 0..) |name, j| if (k & (@as(u8, 1) << @intCast(j)) != 0) {
        w.print("{s}{s}", .{ if (n > 0) ", " else "", name }) catch break;
        n += 1;
    };
    return w.buffered();
}

const t = std.testing;

fn expectScan(in: []const u8, want: []const u8, hits: u32) !void {
    var b: [1024]u8 = undefined;
    @memcpy(b[0..in.len], in);
    const r = scan(b[0..in.len]);
    try t.expectEqualStrings(want, b[0..r.len]);
    try t.expectEqual(hits, r.hits);
}

// The shapes are put together at comptime, never written whole (secret scanners flag them).
const aws_id = "AK" ++ "IA" ++ "Z3QX7M2LPNW4RTY6";
const ghp = "gh" ++ "p_" ++ "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3z5A";
const sk = "sk" ++ "-ant-api03-" ++ "Q7d9KfL2mN4pR6sT8vW0xY2zA4bC6eG8hJ0k-Xy_Z";
const slk = "xo" ++ "xp-" ++ "2741063-48261957-Zq9VbN3mK7wR";
const jw = "ey" ++ "JhbGciOiJIUzI1NiJ9.ey" ++ "JzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const pem_key = "-----BEGIN OPENSSH " ++ "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH " ++ "PRIVATE KEY-----";

test "each shape is replaced; the text around it is kept" {
    try expectScan("AWS_ACCESS_KEY_ID=" ++ aws_id ++ "\n", "AWS_ACCESS_KEY_ID=[REDACTED]\n", 1);
    try expectScan("token: " ++ ghp ++ " ok", "token: [REDACTED] ok", 1);
    try expectScan("\"" ++ sk ++ "\"", "\"[REDACTED]\"", 1);
    try expectScan(slk, "[REDACTED]", 1);
    try expectScan("Bearer " ++ jw ++ ".", "Bearer [REDACTED].", 1);
    try expectScan("key:\n" ++ pem_key ++ "\nafter", "key:\n[REDACTED]\nafter", 1);
    try expectScan(aws_id ++ " " ++ ghp, "[REDACTED] [REDACTED]", 2);
}

test "a PEM block cut off before END runs to the end of the key body" {
    try expectScan("-----BEGIN RSA " ++ "PRIVATE KEY-----\nMIIEowIBAAKCAQEAq7Bz\nq7Bzq7Bzq7Bzq7Bzq7Bz", "[REDACTED]", 1);
    // in JSON text the closing quote ends it, so the line stays valid
    try expectScan("{\"c\":\"-----BEGIN RSA " ++ "PRIVATE KEY-----\\nMIIEowIBAAKCAQEAq7Bzq7Bzq7Bzq7Bz\"}", "{\"c\":\"[REDACTED]\"}", 1);
    // too short to be a key body: a header with a word after it
    try expectScan("-----BEGIN RSA " ++ "PRIVATE KEY-----\nMIIE", "-----BEGIN RSA " ++ "PRIVATE KEY-----\nMIIE", 0);
}

test "a header that is only mentioned is kept, and never reaches a later END" {
    const same = [_][]const u8{
        "the -----BEGIN EC " ++ "PRIVATE KEY----- line starts the file",
        "-----BEGIN RSA " ++ "PRIVATE KEY-----\nThis key was rotated, see the vault.\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----",
        "{\"c\":\"-----BEGIN RSA " ++ "PRIVATE KEY-----\"}\n{\"c\":\"x -----END CERTIFICATE-----\"}",
    };
    for (same) |s| try expectScan(s, s, 0);
    try expectScan("-----BEGIN RSA " ++ "PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,3F17F5316E2BAC89\n\nMIIEowIBAAKC\n-----END RSA " ++ "PRIVATE KEY-----\nnext", "[REDACTED]\nnext", 1);
}

test "JSON-escaped text (a resumed session): a key after \\n still starts a word" {
    try expectScan("\"AWS=x\\n" ++ aws_id ++ "\\n\"", "\"AWS=x\\n[REDACTED]\\n\"", 1);
}

test "look-alikes pass unchanged" {
    const same = [_][]const u8{
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        "123e4567-e89b-12d3-a456-426614174000",
        "aGVsbG8gd29ybGQgdGhpcyBpcyBhIGJhc2U2NCB0ZXN0IGZpeHR1cmU=",
        "task-runner-configuration-for-the-whole-build disk-usage-report",
        "sk-learn-model-selection-and-cross-validation",
        "AKIA_IS_NOT_A_KEY AKIAshort -----BEGIN CERTIFICATE----- -----BEGIN PUBLIC KEY-----",
        "x" ++ aws_id, // inside a word
        "mask-" ++ "Q7d9KfL2mN4pR6sT8vW0xY2zA4bC6eG8hJ0k", // "sk-" inside a word
        "ghp_short gho_ xoxb-nodigitsatall eyJhbGciOi.notjwt",
        "",
    };
    for (same) |s| try expectScan(s, s, 0);
}

test "names lists the kinds found" {
    var nb: [128]u8 = undefined;
    try t.expectEqualStrings("private key, GitHub token", names(0b101, &nb));
}
