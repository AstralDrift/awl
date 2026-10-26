//! OpenAI-compatible chat streaming: SSE events → content, reasoning, tool calls.
const std = @import("std");
const Int = @import("jint.zig").Int;
const Str = @import("jint.zig").Str;
const http = @import("http.zig");
const sys = @import("sys.zig");
const ui = @import("ui.zig");
const Buf = @import("buf.zig").Buf;

pub const Cfg = struct {
    url: http.Url,
    key: ?[]const u8 = null,
    model: []const u8 = "",
};

pub const Small = struct {
    b: [128]u8 = undefined,
    n: usize = 0,
    pub fn get(self: *const Small) []const u8 {
        return self.b[0..self.n];
    }
    pub fn add(self: *Small, s: []const u8) void {
        const k = @min(s.len, self.b.len - self.n);
        @memcpy(self.b[self.n .. self.n + k], s[0..k]);
        self.n += k;
    }
};

pub const max_calls = 16;
pub const Call = struct {
    id: Small = .{},
    name: Small = .{},
    args: Buf = Buf.init(32 << 20),
};

pub const Turn = struct {
    content: Buf = Buf.init(32 << 20),
    reasoning: Buf = Buf.init(32 << 20), // sent back with the turn (AWL_KEEP_REASONING)
    calls: [max_calls]Call = [_]Call{.{}} ** max_calls,
    n: usize = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    reasoning_bytes: usize = 0,
    length_cut: bool = false,

    pub fn reset(self: *Turn) void {
        self.content.reset();
        self.reasoning.reset();
        for (self.calls[0..self.n]) |*c| {
            c.args.reset();
            c.id.n = 0;
            c.name.n = 0;
        }
        self.n = 0;
        self.completion_tokens = 0;
        self.reasoning_bytes = 0;
        self.length_cut = false;
    }
};

const Chunk = struct {
    choices: []const struct {
        delta: struct {
            content: ?Str = null,
            reasoning_content: ?Str = null,
            reasoning: ?Str = null,
            tool_calls: ?[]const struct {
                index: ?Int(usize) = null,
                id: ?Str = null,
                function: ?struct {
                    name: ?Str = null,
                    arguments: ?Str = null,
                } = null,
            } = null,
        } = .{},
        finish_reason: ?Str = null,
    } = &.{},
    usage: ?struct {
        prompt_tokens: Int(u64) = .{ .v = 0 },
        completion_tokens: Int(u64) = .{ .v = 0 },
    } = null,
    @"error": ?struct { message: ?Str = null } = null,
};

var scratch: [256 * 1024]u8 = undefined;

pub const Error = http.Error || error{ Status, Server };

/// Status/error detail for the last failure (for messages).
pub var detail: [512]u8 = undefined;
/// HTTP status of the last non-200 reply (0 when the failure was not an HTTP status).
pub var last_status: u16 = 0;
pub var detail_len: usize = 0;
fn setDetail(s: []const u8) void {
    detail_len = @min(s.len, detail.len);
    @memcpy(detail[0..detail_len], s[0..detail_len]);
}

pub fn stream(cfg: Cfg, body: []const []const u8, t: *Turn) Error!void {
    last_status = 0;
    const fd = try http.connect(cfg.url);
    var r = http.Response{ .fd = fd };
    defer r.deinit();
    try http.send(fd, cfg.url, "POST", "/v1/chat/completions", cfg.key, body);
    try r.readHead();
    if (r.status != 200) {
        var eb = Buf.init(4096);
        defer eb.free();
        while (try r.body()) |b| {
            eb.add(b);
            if (eb.full()) break;
        }
        var tmp: [512]u8 = undefined;
        setDetail(std.fmt.bufPrint(&tmp, "HTTP {d}: {s}", .{ r.status, eb.items() }) catch "HTTP error");
        last_status = r.status;
        return error.Status;
    }
    while (try r.nextLine()) |line| {
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        try event(data, t);
    }
}

fn event(data: []const u8, t: *Turn) Error!void {
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const c = std.json.parseFromSliceLeaky(Chunk, fba.allocator(), data, .{ .ignore_unknown_fields = true }) catch {
        setDetail(data);
        return error.Server;
    };
    if (c.@"error") |e| {
        setDetail(if (e.message) |x| x.v else data);
        return error.Server;
    }
    if (c.usage) |u| {
        t.prompt_tokens = u.prompt_tokens.v;
        t.completion_tokens = u.completion_tokens.v;
    }
    for (c.choices) |ch| {
        const d = ch.delta;
        if (d.reasoning_content orelse d.reasoning) |rs| {
            const s = rs.v;
            t.reasoning_bytes += s.len;
            t.reasoning.add(s);
            ui.reasoning(s);
        }
        if (d.content) |cs| if (cs.v.len > 0) {
            const s = cs.v;
            t.content.add(s);
            ui.content(s);
        };
        if (d.tool_calls) |tcs| for (tcs) |tc| {
            const i = if (tc.index) |x| x.v else (if (t.n > 0) t.n - 1 else 0);
            if (i >= max_calls) continue;
            if (i >= t.n) t.n = i + 1;
            const call = &t.calls[i];
            if (tc.id) |id| if (call.id.n == 0) call.id.add(id.v);
            if (tc.function) |f| {
                if (f.name) |n| call.name.add(n.v);
                if (f.arguments) |a| call.args.add(a.v);
            }
        };
        if (ch.finish_reason) |f| if (std.mem.eql(u8, f.v, "length")) {
            t.length_cut = true;
        };
    }
}

pub const ModelInfo = struct { id: []const u8, ctx: u64 };

/// First model from GET /v1/models: id (copied into `out`) and context length if reported.
pub fn firstModel(cfg: Cfg, out: []u8) Error!ModelInfo {
    var ids = Buf.init(64 << 10);
    defer ids.free();
    var one: [1]ModelInfo = undefined;
    const l = try models(cfg, &ids, &one);
    const n = @min(out.len, l[0].id.len);
    @memcpy(out[0..n], l[0].id[0..n]);
    return .{ .id = out[0..n], .ctx = l[0].ctx };
}

/// Every model GET /v1/models lists (at most out.len); ids are copied into `ids`.
pub fn models(cfg: Cfg, ids: *Buf, out: []ModelInfo) Error![]ModelInfo {
    const fd = try http.connect(cfg.url);
    var r = http.Response{ .fd = fd };
    defer r.deinit();
    try http.send(fd, cfg.url, "GET", "/v1/models", cfg.key, &.{});
    try r.readHead();
    var b = Buf.init(16 << 20); // OpenRouter lists hundreds, with descriptions
    defer b.free();
    while (try r.body()) |x| b.add(x);
    if (r.status != 200) return error.Status;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const M = struct { data: []const struct { id: Str, max_model_len: ?Int(u64) = null, context_length: ?Int(u64) = null } = &.{} };
    const m = std.json.parseFromSliceLeaky(M, fba.allocator(), b.items(), .{ .ignore_unknown_fields = true }) catch return error.Server;
    if (m.data.len == 0) return error.Server;
    const k = @min(out.len, m.data.len);
    for (m.data[0..k], 0..) |d, i| {
        const start = ids.len;
        ids.add(d.id.v);
        out[i] = .{ .id = ids.items()[start..ids.len], .ctx = if (d.max_model_len orelse d.context_length) |c| c.v else 0 };
    }
    return out[0..k];
}

test "event accumulates content and split tool calls" {
    var t = Turn{};
    ui.quiet = true;
    try event("{\"choices\":[{\"delta\":{\"content\":\"he\"}}]}", &t);
    try event("{\"choices\":[{\"delta\":{\"content\":\"llo \\u00e9\"}}]}", &t);
    try event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"pa\"}}]}}]}", &t);
    try event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"th\\\":\\\"a\\\"}\"}}]}}]}", &t);
    try event("{\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}", &t);
    try std.testing.expectEqualStrings("hello é", t.content.items());
    try std.testing.expectEqual(@as(usize, 1), t.n);
    try std.testing.expectEqualStrings("c1", t.calls[0].id.get());
    try std.testing.expectEqualStrings("read", t.calls[0].name.get());
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", t.calls[0].args.items());
    try std.testing.expectEqual(@as(u64, 7), t.prompt_tokens);
    t.reset();
    try std.testing.expectEqual(@as(usize, 0), t.n);
}
