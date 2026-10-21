//! The loop: user → model → tools → model … until a reply has no tool calls.
//! The conversation is kept as pre-serialized JSON, so a request is three
//! writes to the socket (head, messages, tail) with no rebuild.
const std = @import("std");
const sys = @import("sys.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const bufm = @import("buf.zig");
const Buf = bufm.Buf;

pub var cfg: llm.Cfg = undefined;
pub var max_steps: usize = 50;
var head = Buf.init(1 << 20); // {"model":…,"tools":[…],"messages":[{system}
var msgs = Buf.init(1 << 30); // ,{msg},{msg}…
var turn = llm.Turn{};
var out = Buf.init(tools.out_cap + 4096);
pub var ctx_tokens: u64 = 0;
pub var n_msgs: usize = 0;

const base_prompt =
    \\You are awl, a coding agent in a terminal on Omarchy Linux. You complete software tasks in the working directory by calling tools.
    \\- Read a file before you edit it. Use edit for changes, write for new files.
    \\- Use grep and find to search; they are faster than bash.
    \\- Check your work: run the tests or the program.
    \\- Keep replies short. When done, say what you changed.
;

pub fn init(cwd: []const u8) void {
    head.add("{\"model\":");
    bufm.str(&head, cfg.model);
    head.add(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"tools\":[");
    tools.schema(&head);
    head.add("],\"messages\":[{\"role\":\"system\",\"content\":\"");
    var pb: [16384]u8 = undefined;
    const base = if (sys.getenv("AWL_SYSTEM")) |p| (sys.readFile(p, &pb) catch base_prompt) else base_prompt;
    bufm.escape(&head, base);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(sys.wallSec()) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    var tb: [600]u8 = undefined;
    bufm.escape(&head, std.fmt.bufPrint(&tb, "\nTools: {s}.\nWorking directory: {s}\nDate: {d}-{d:0>2}-{d:0>2}", .{ tools.names(), cwd, yd.year, md.month.numeric(), md.day_index + 1 }) catch "");
    addAgentsMd(cwd);
    head.add("\"}");
}

/// AGENTS.md from the cwd, plus the git root's when that is a different directory.
fn addAgentsMd(cwd: []const u8) void {
    var fb: [32768]u8 = undefined;
    var pb: [4200]u8 = undefined;
    if (sys.readFile(std.fmt.bufPrint(&pb, "{s}/AGENTS.md", .{cwd}) catch return, &fb)) |t| {
        bufm.escape(&head, "\n\n# AGENTS.md\n");
        bufm.escape(&head, t);
    } else |_| {}
    var d = cwd;
    while (std.mem.lastIndexOfScalar(u8, d, '/')) |i| {
        if (sys.exists(std.fmt.bufPrint(&pb, "{s}/.git", .{d}) catch return)) break;
        if (i == 0) return;
        d = d[0..i];
    }
    if (d.len == cwd.len) return;
    if (sys.readFile(std.fmt.bufPrint(&pb, "{s}/AGENTS.md", .{d}) catch return, &fb)) |t| {
        bufm.escape(&head, "\n\n# AGENTS.md (repo root)\n");
        bufm.escape(&head, t);
    } else |_| {}
}

pub fn resume_(path: []const u8) !usize {
    n_msgs = try session.load(path, &msgs);
    return n_msgs;
}

pub fn clear() void {
    msgs.reset();
    n_msgs = 0;
    ctx_tokens = 0;
}

/// Append one message (JSON object text in `scratch`) to the conversation and the session log.
fn push(m: *Buf) void {
    msgs.byte(',');
    msgs.add(m.items());
    session.append(m.items());
    n_msgs += 1;
}

pub fn user(text: []const u8) void {
    var m = Buf.init(text.len * 6 + 64);
    defer m.free();
    m.add("{\"role\":\"user\",\"content\":");
    bufm.str(&m, text);
    m.byte('}');
    push(&m);
}

pub const Outcome = enum { done, cancelled, failed, max_steps };

pub fn run() Outcome {
    var step: usize = 0;
    while (step < max_steps) : (step += 1) {
        turn.reset();
        const t0 = sys.nowNs();
        llm.stream(cfg, &.{ head.items(), msgs.items(), "]}" }, &turn) catch |e| {
            ui.endMessage();
            switch (e) {
                error.Cancel => {
                    ui.note("interrupted", .{});
                    return .cancelled;
                },
                error.Connect => ui.err("cannot reach the model at {s}. Is a Local AI model running?", .{cfg.url.host}),
                error.Status, error.Server => ui.err("model error: {s}", .{llm.detail[0..llm.detail_len]}),
                else => ui.err("stream failed: {s}", .{@errorName(e)}),
            }
            return .failed;
        };
        ui.endMessage();
        const secs = @as(f64, @floatFromInt(sys.nowNs() - t0)) / 1e9;
        ctx_tokens = turn.prompt_tokens + turn.completion_tokens;
        pushAssistant(step);
        if (turn.n == 0) {
            ui.status(cfg.model, turn.completion_tokens, secs, ctx_tokens);
            if (turn.length_cut) ui.note("reply cut off at the max token limit", .{});
            return .done;
        }
        for (turn.calls[0..turn.n], 0..) |*c, i| {
            out.reset();
            const r = tools.run(c.name.get(), c.args.items(), &out) catch {
                ui.toolOutput(out.items(), false);
                pushResult(c, step, i, out.items());
                for (turn.calls[i + 1 .. turn.n], i + 1..) |*rest, j| pushResult(rest, step, j, "[skipped: interrupted by user]");
                ui.note("interrupted", .{});
                return .cancelled;
            };
            ui.toolOutput(out.items(), r.ok);
            pushResult(c, step, i, out.items());
        }
    }
    ui.err("stopped after {d} steps (AWL_MAX_STEPS)", .{max_steps});
    return .max_steps;
}

fn callId(c: *const llm.Call, step: usize, i: usize, b: []u8) []const u8 {
    if (c.id.n > 0) return c.id.get();
    return std.fmt.bufPrint(b, "call_{d}_{d}", .{ step, i }) catch "call";
}

fn pushAssistant(step: usize) void {
    var m = Buf.init(turn.content.len * 6 + (1 << 20));
    defer m.free();
    m.add("{\"role\":\"assistant\",\"content\":");
    bufm.str(&m, turn.content.items());
    if (turn.n > 0) {
        m.add(",\"tool_calls\":[");
        for (turn.calls[0..turn.n], 0..) |*c, i| {
            if (i > 0) m.byte(',');
            var ib: [64]u8 = undefined;
            m.add("{\"id\":");
            bufm.str(&m, callId(c, step, i, &ib));
            m.add(",\"type\":\"function\",\"function\":{\"name\":");
            bufm.str(&m, c.name.get());
            m.add(",\"arguments\":");
            bufm.str(&m, if (c.args.len == 0) "{}" else c.args.items());
            m.add("}}");
        }
        m.byte(']');
    }
    m.byte('}');
    push(&m);
}

fn pushResult(c: *const llm.Call, step: usize, i: usize, text: []const u8) void {
    var m = Buf.init(text.len * 6 + 256);
    defer m.free();
    var ib: [64]u8 = undefined;
    m.add("{\"role\":\"tool\",\"tool_call_id\":");
    bufm.str(&m, callId(c, step, i, &ib));
    m.add(",\"content\":");
    bufm.str(&m, text);
    m.byte('}');
    push(&m);
}
