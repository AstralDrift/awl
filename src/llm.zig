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
/// AWL_THINK_MAX (tokens, kept as bytes at ~4 per token): stop a reply whose thinking runs past this before it acts. 0 = off.
pub var think_max: usize = 0;
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
    // The reply started a call past max_calls: the stream was stopped there (a model stuck repeating near-identical
    // calls once wrote 171 in one reply, 17K tokens), and only the first max_calls run.
    overflow: bool = false,
    // Reasoning passed think_max before any content or call (AWL_THINK_MAX): the stream was stopped there.
    think_cut: bool = false,

    pub fn reset(self: *Turn) void {
        self.content.reset();
        self.reasoning.reset();
        for (self.calls[0..self.n]) |*c| {
            c.args.reset();
            c.id.n = 0;
            c.name.n = 0;
        }
        self.n = 0;
        self.prompt_tokens = 0;
        self.completion_tokens = 0;
        self.reasoning_bytes = 0;
        self.length_cut = false;
        self.overflow = false;
        self.think_cut = false;
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
    var r = http.Response{ .fd = fd, .tls = cfg.url.tls };
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
    var events: usize = 0;
    var first: [200]u8 = undefined;
    var first_n: usize = 0;
    while (try r.nextLine()) |line| {
        if (first_n == 0 and line.len > 0) {
            first_n = @min(line.len, first.len);
            @memcpy(first[0..first_n], line[0..first_n]);
        }
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        events += 1;
        const data = std.mem.trim(u8, line[5..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        try event(data, t);
        if (t.overflow or t.think_cut) break; // closing the connection makes the server stop generating
    }
    if (events == 0) { // a 200 that is not an event stream (stream: true ignored, a proxy's page): not an empty reply
        var tmp: [300]u8 = undefined;
        setDetail(std.fmt.bufPrint(&tmp, "the server sent no event stream (not SSE): {s}", .{first[0..first_n]}) catch "no event stream");
        return error.Server;
    }
}

fn event(data: []const u8, t: *Turn) Error!void {
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    // An event bigger than the scratch (a server that sends whole tool arguments in one delta,
    // a buffering proxy) gets heap pages for this one parse instead of failing the run.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = if (data.len * 4 > scratch.len) arena.allocator() else fba.allocator();
    const c = std.json.parseFromSliceLeaky(Chunk, alloc, data, .{ .ignore_unknown_fields = true }) catch {
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
            if (think_max > 0 and t.reasoning_bytes > think_max and t.n == 0 and t.content.len == 0) {
                t.think_cut = true;
                return;
            }
        }
        if (d.content) |cs| if (cs.v.len > 0) {
            const s = cs.v;
            t.content.add(s);
            ui.content(s);
        };
        if (d.tool_calls) |tcs| for (tcs) |tc| {
            // No index (some servers): a delta with a new id opens the next call, the rest continue the last one.
            const new_id = tc.id != null and tc.id.?.v.len > 0 and (t.n == 0 or !std.mem.eql(u8, t.calls[t.n - 1].id.get(), tc.id.?.v));
            const i = if (tc.index) |x| x.v else if (t.n == 0) 0 else if (new_id) t.n else t.n - 1;
            if (i >= max_calls) {
                t.overflow = true;
                return;
            }
            if (i >= t.n) t.n = i + 1;
            const call = &t.calls[i];
            if (tc.id) |id| if (call.id.n == 0) call.id.add(id.v);
            if (tc.function) |f| {
                if (f.name) |n| call.name.add(n.v);
                if (f.arguments) |a| call.args.add(a.v);
                ui.forming(call.name.get(), call.args.len);
            }
        };
        if (ch.finish_reason) |f| if (std.mem.eql(u8, f.v, "length")) {
            t.length_cut = true;
        };
    }
}

pub const ModelInfo = struct { id: []const u8, ctx: u64 };

/// The model to use, from GET /v1/models: `want` (AWL_MODEL) when the server lists it, else the first
/// one. The id is copied into `out`; ctx is the context length the server reports for that model, or 0.
/// A wanted model the list does not name keeps a single-model server's one length (vLLM's
/// --served-model-name alias is a common case) and is otherwise unknown (AWL_CTX sets it).
pub fn pickModel(cfg: Cfg, want: ?[]const u8, out: []u8) Error!ModelInfo {
    var ids = Buf.init(1 << 20);
    defer ids.free();
    var list: [1024]ModelInfo = undefined;
    const l = try models(cfg, &ids, &list);
    var pick = l[0];
    if (want) |w| {
        pick.ctx = if (l.len == 1) l[0].ctx else 0;
        for (l) |m| if (std.mem.eql(u8, m.id, w)) {
            pick = m;
            break;
        };
    }
    const n = @min(out.len, pick.id.len);
    @memcpy(out[0..n], pick.id[0..n]);
    return .{ .id = out[0..n], .ctx = pick.ctx };
}

/// Every model GET /v1/models lists (at most out.len); ids are copied into `ids`.
pub fn models(cfg: Cfg, ids: *Buf, out: []ModelInfo) Error![]ModelInfo {
    const fd = try http.connect(cfg.url);
    var r = http.Response{ .fd = fd, .tls = cfg.url.tls };
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
    // no index: a new id opens the next call, deltas without one continue the last
    try event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"c2\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"co\"}}]}}]}", &t);
    try event("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"mmand\\\":\\\"ls\\\"}\"}}]}}]}", &t);
    try std.testing.expectEqual(@as(usize, 2), t.n);
    try std.testing.expectEqualStrings("bash", t.calls[1].name.get());
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", t.calls[1].args.items());
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", t.calls[0].args.items());
    try std.testing.expectEqualStrings("c1", t.calls[0].id.get());
    try std.testing.expectEqualStrings("read", t.calls[0].name.get());
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", t.calls[0].args.items());
    try std.testing.expectEqual(@as(u64, 7), t.prompt_tokens);
    t.reset();
    try std.testing.expectEqual(@as(usize, 0), t.n);
}
