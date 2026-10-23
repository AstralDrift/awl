//! The loop: user → model → tools → model … until a reply has no tool calls.
//! The conversation is kept as pre-serialized JSON, so a request is three
//! writes to the socket (head, messages, tail) with no rebuild.
const std = @import("std");
const sys = @import("sys.zig");
const llm = @import("llm.zig");
const http = @import("http.zig");
const tools = @import("tools.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const skills = @import("skills.zig");
const undo = @import("undo.zig");
const Str = @import("jint.zig").Str;
const bufm = @import("buf.zig");
const Buf = bufm.Buf;

pub var cfg: llm.Cfg = undefined;
pub var max_steps: usize = 200;
var head = Buf.init(1 << 20); // {"model":…,"tools":[…],"messages":[{system}
var msgs = Buf.init(1 << 30); // ,{msg},{msg}…
var turn = llm.Turn{};
var out = Buf.init(tools.out_cap + 4096);
pub var ctx_tokens: u64 = 0;
pub var ctx_limit: u64 = 0; // from the server; 0 = unknown
pub var n_msgs: usize = 0;
pub var n_agents_md: usize = 0; // AGENTS.md files loaded (for the welcome screen)
pub var n_skills: usize = 0;
// Start offset of each message in `msgs` (at its leading comma), for elision.
const max_index = 16384;
var offs: [max_index]usize = undefined;

const base_prompt =
    \\You are awl, a coding agent in a terminal on Omarchy Linux. You complete software tasks in the working directory by calling tools.
    \\- Read a file before you edit it. Use edit for changes, write for new files.
    \\- Use grep and find to search; they are faster than bash.
    \\- Check your work: run the tests or the program. Say something works only when tool output shows it.
    \\- Keep replies short. When done, say what you changed.
;

pub fn init(cwd: []const u8) void {
    head.add("{\"model\":");
    bufm.str(&head, cfg.model);
    head.add(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
    // Reasoning level. Default medium, as pi sends: Local AI's Qwen defaults to xhigh,
    // which wrote about twice the tokens per turn for the same work. AWL_REASONING=off
    // sends nothing; a server that rejects the field gets the request again without it.
    const effort = sys.getenv("AWL_REASONING") orelse "medium";
    if (effort.len > 0 and !std.mem.eql(u8, effort, "off")) {
        head.add(",\"reasoning_effort\":");
        bufm.str(&head, effort);
    }
    // Output cap per reply (AWL_MAX_TOKENS, 0 = none). Without one, Qwen sometimes
    // reasons in a loop: one Terminal-Bench reply ran 69K tokens and ate a task's
    // whole time limit. pi sends the same 16384.
    const cap = std.fmt.parseInt(u32, sys.getenv("AWL_MAX_TOKENS") orelse "16384", 10) catch 16384;
    if (cap > 0) head.print(",\"max_tokens\":{d}", .{cap});
    head.add(",\"tools\":[");
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
    var hb: [1024]u8 = undefined;
    var rb: [1024]u8 = undefined;
    const user_dir = if (sys.getenv("HOME")) |h| (std.fmt.bufPrint(&hb, "{s}/.agents/skills", .{h}) catch "") else "";
    const proj_dir = std.fmt.bufPrint(&rb, "{s}/.agents/skills", .{projectRoot(cwd)}) catch "";
    n_skills = skills.add(&head, if (std.mem.eql(u8, user_dir, proj_dir)) &.{user_dir} else &.{ proj_dir, user_dir });
    head.add("\"}");
}

var model_b: [256]u8 = undefined;

/// Switch models for the next request (the conversation is kept).
pub fn setModel(name: []const u8) void {
    const k = @min(name.len, model_b.len);
    @memcpy(model_b[0..k], name[0..k]);
    cfg.model = model_b[0..k];
    const rest = std.mem.indexOf(u8, head.items(), ",\"stream\":") orelse return;
    var tail = Buf.init(head.len);
    defer tail.free();
    tail.add(head.items()[rest..]);
    head.reset();
    head.add("{\"model\":");
    bufm.str(&head, cfg.model);
    head.add(tail.items());
}

pub fn compactNow() bool {
    return compact(true);
}

pub fn systemBytes() usize {
    return head.len;
}

/// The git root containing `cwd`, or `cwd` itself outside a repository.
pub fn projectRoot(cwd: []const u8) []const u8 {
    var pb: [4200]u8 = undefined;
    var d = cwd;
    while (true) {
        if (sys.exists(std.fmt.bufPrint(&pb, "{s}/.git", .{d}) catch return cwd)) return d;
        const i = std.mem.lastIndexOfScalar(u8, d, '/') orelse return cwd;
        if (i == 0) return cwd;
        d = d[0..i];
    }
}

/// AGENTS.md files, outermost first so the nearest comes last and wins conflicts:
/// the user's own file ($XDG_CONFIG_HOME/awl/AGENTS.md, else ~/.config/awl/AGENTS.md),
/// then the git root down to the cwd (outside a repository, the cwd only). Nothing
/// above the repository: a parent folder's rules belong to other projects or tools.
/// AWL_AGENTS=off loads none. At most 24 KB in total.
fn addAgentsMd(cwd: []const u8) void {
    if (sys.getenv("AWL_AGENTS")) |v| if (std.mem.eql(u8, v, "off")) return;
    var used: usize = 0;
    var cb: [4200]u8 = undefined;
    const cfg_dir = if (sys.getenv("XDG_CONFIG_HOME")) |x| std.fmt.bufPrint(&cb, "{s}/awl", .{x}) catch null else if (sys.getenv("HOME")) |h| std.fmt.bufPrint(&cb, "{s}/.config/awl", .{h}) catch null else null;
    if (cfg_dir) |d| addAgentsFile(d, &used);
    const root = projectRoot(cwd);
    var ends: [64]usize = undefined; // cwd[0..ends[i]] are the directories, innermost first
    var n: usize = 0;
    var d = cwd;
    while (n < ends.len) {
        ends[n] = d.len;
        n += 1;
        if (d.len <= root.len) break;
        const i = std.mem.lastIndexOfScalar(u8, d, '/') orelse break;
        d = if (i == 0) cwd[0..1] else d[0..i];
    }
    var k = n;
    while (k > 0) {
        k -= 1;
        addAgentsFile(cwd[0..ends[k]], &used);
    }
}

fn addAgentsFile(dir: []const u8, used: *usize) void {
    var fb: [32768]u8 = undefined;
    var pb: [4200]u8 = undefined;
    const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
    const t = sys.readFile(std.fmt.bufPrint(&pb, "{s}{s}AGENTS.md", .{ dir, sep }) catch return, &fb) catch return;
    var hb: [4300]u8 = undefined;
    if (used.* + t.len > 24 * 1024) {
        bufm.escape(&head, std.fmt.bufPrint(&hb, "\n\n# {s}{s}AGENTS.md skipped (over the 24 KB AGENTS.md budget)\n", .{ dir, sep }) catch "");
        return;
    }
    used.* += t.len;
    n_agents_md += 1;
    bufm.escape(&head, std.fmt.bufPrint(&hb, "\n\n# AGENTS.md from {s}\n", .{dir}) catch "\n\n# AGENTS.md\n");
    bufm.escape(&head, t);
}

pub fn resume_(path: []const u8) !usize {
    return try session.load(path, addLoaded);
}

fn addLoaded(line: []const u8) void {
    add(line);
}

fn add(json: []const u8) void {
    if (n_msgs < max_index) offs[n_msgs] = msgs.len;
    msgs.byte(',');
    msgs.add(json);
    n_msgs += 1;
}

pub fn clear() void {
    msgs.reset();
    n_msgs = 0;
    ctx_tokens = 0;
}

/// Append one message (JSON object text in `scratch`) to the conversation and the session log.
fn push(m: *Buf) void {
    add(m.items());
    session.append(m.items());
}

const tool_prefix = "{\"role\":\"tool\",\"tool_call_id\":";
const elided = "[old tool output elided to save context; rerun the tool if you need it]";

/// When the prompt passes 60% of the window, replace the oldest large tool
/// outputs with a placeholder until the estimate drops under 40%. The last
/// 8 messages are never touched. The session log keeps the full text.
fn elide() void {
    if (ctx_limit == 0 or n_msgs > max_index) return;
    if (ctx_tokens * 10 < ctx_limit * 6) return;
    const before = msgs.len;
    const target = ctx_limit * 4 / 10;
    var nb = Buf.init(msgs.cap);
    const items = msgs.items();
    var saved: usize = 0;
    var count: usize = 0;
    for (0..n_msgs) |i| {
        const start = offs[i];
        const end = if (i + 1 < n_msgs) offs[i + 1] else items.len;
        const m = items[start + 1 .. end];
        offs[i] = nb.len;
        const est = ctx_tokens - ctx_tokens * saved / before;
        const is_todo = std.mem.indexOf(u8, m[0..@min(m.len, 200)], "\"content\":\"" ++ tools.todo_marker) != null;
        if (i + 8 < n_msgs and est > target and m.len > 400 and !is_todo and std.mem.startsWith(u8, m, tool_prefix)) {
            // the id is the JSON string right after the prefix (ids never contain quotes)
            const rest = m[tool_prefix.len..];
            if (rest.len > 1 and rest[0] == '"') if (std.mem.indexOfScalarPos(u8, rest, 1, '"')) |q| {
                const before_len = nb.len;
                nb.add("," ++ tool_prefix);
                nb.add(rest[0 .. q + 1]);
                nb.add(",\"content\":\"" ++ elided ++ "\"}");
                saved += (end - start) -| (nb.len - before_len);
                count += 1;
                continue;
            };
        }
        nb.add(items[start..end]);
    }
    if (count == 0) {
        nb.free();
        if (ctx_tokens * 10 > ctx_limit * 9) ui.note("context nearly full ({d}k of {d}k); /clear to start fresh", .{ ctx_tokens / 1000, ctx_limit / 1000 });
        return;
    }
    msgs.free();
    msgs = nb;
    const freed = ctx_tokens * saved / before;
    ui.note("elided {d} old tool outputs (~{d}k tokens) to stay inside the context window", .{ count, freed / 1000 });
    ctx_tokens -|= freed;
}

/// Said to the model with the next user message (e.g. what /undo restored).
pub var pending_note = Buf.init(64 << 10);
pub var mode_note: []const u8 = ""; // the latest /mode change, said once

pub fn user(text: []const u8) void {
    undo.newTurn();
    addUser(text);
}

/// A message steered in mid-run: same /undo group as the turn it joins.
fn addUser(text: []const u8) void {
    var m = Buf.init(text.len * 6 + pending_note.len * 6 + 64);
    defer m.free();
    m.add("{\"role\":\"user\",\"content\":");
    if (mode_note.len > 0) {
        var keep = Buf.init(64 << 10);
        defer keep.free();
        keep.add(pending_note.items());
        pending_note.reset();
        pending_note.add(mode_note);
        if (keep.len > 0) pending_note.add("\n");
        pending_note.add(keep.items());
        mode_note = "";
    }
    if (pending_note.len > 0) {
        pending_note.add("\n\n");
        pending_note.add(text);
        bufm.str(&m, pending_note.items());
        pending_note.reset();
    } else bufm.str(&m, text);
    m.byte('}');
    push(&m);
}

pub const Outcome = enum { done, cancelled, failed, max_steps };

/// Messages the user typed while the agent worked; taken before each later step.
pub var steer: ?*const fn () ?[]const u8 = null;

/// The last run, for the summary line and notifications.
pub var run_secs: f64 = 0;

pub fn run() Outcome {
    const run_t0 = sys.nowNs();
    const changed0 = tools.files_changed.n;
    defer run_secs = @as(f64, @floatFromInt(sys.nowNs() - run_t0)) / 1e9;
    var step: usize = 0;
    var forced = false; // one forced compaction per run after a "too long" rejection
    while (step < max_steps) : (step += 1) {
        if (step > 0) {
            if (steer) |f| if (f()) |text| {
                ui.userEcho(text);
                addUser(text);
            };
            _ = compact(false);
        }
        ui.liveStart();
        const t0 = sys.nowNs();
        streamRetrying(msgs.items(), "]}") catch |e| {
            ui.endMessage();
            if (e == error.Status and llm.last_status == 400 and !forced and tooLong() and compact(true)) {
                forced = true;
                step -|= 1;
                continue;
            }
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
        elide();
        if (turn.n == 0 and turn.length_cut) { // cut off mid-thought: let it go on
            ui.note("reply cut off at the max token limit (AWL_MAX_TOKENS); asking the model to continue", .{});
            addUser(cut_note);
            continue;
        }
        if (turn.n == 0) {
            _ = secs;
            ui.status(cfg.model, @as(f64, @floatFromInt(sys.nowNs() - run_t0)) / 1e9, step + 1, tools.files_changed.n - changed0, ctx_tokens, ctx_limit);
            return .done;
        }
        for (turn.calls[0..turn.n], 0..) |*c, i| {
            out.reset();
            const r = tools.run(c.name.get(), c.args.items(), &out) catch {
                // the model gets the "[interrupted by user]" marker; the screen says it once, below
                const o = out.items();
                const shown = std.mem.trimEnd(u8, if (std.mem.endsWith(u8, o, "[interrupted by user]")) o[0 .. o.len - 21] else o, "\n");
                if (shown.len > 0) ui.toolOutput(shown, false);
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

const cut_note = "[Your last reply hit the output token limit before it finished. Think more briefly: make the next tool call now, or give your answer.]";

pub var max_retries: u32 = 5;

/// The server refused the request because of reasoning_effort: stop sending it.
fn dropReasoning() bool {
    const d = llm.detail[0..llm.detail_len];
    if (std.ascii.indexOfIgnoreCase(d, "reasoning") == null) return false;
    const h = head.items();
    const i = std.mem.indexOf(u8, h, ",\"reasoning_effort\":\"") orelse return false;
    const end = std.mem.indexOfScalarPos(u8, h, i + 21, '"') orelse return false;
    const n = end + 1 - i;
    std.mem.copyForwards(u8, h[i .. h.len - n], h[end + 1 ..]);
    head.len -= n;
    ui.note("the server does not take reasoning_effort ({s}); continuing without it", .{d[0..@min(d.len, 120)]});
    return true;
}

/// One model request, retried with backoff (1, 2, 4, 8, 16 s) on failures that are
/// usually transient: connection loss, 408/425/429/5xx, provider error events. Only
/// retried while nothing of the reply has arrived, so output is never duplicated.
fn streamRetrying(mid: []const u8, tail: []const u8) llm.Error!void {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        turn.reset();
        llm.stream(cfg, &.{ head.items(), mid, tail }, &turn) catch |e| {
            const transient = switch (e) {
                error.Cancel => false,
                error.Status => switch (llm.last_status) {
                    408, 425, 429, 500, 502, 503, 504 => true,
                    else => false,
                },
                else => true,
            };
            if (e == error.Status and llm.last_status == 400 and dropReasoning()) {
                attempt -|= 1;
                continue;
            }
            if (!transient or attempt >= max_retries or turn.content.len > 0 or turn.n > 0) return e;
            const secs = @as(u32, 1) << @intCast(@min(attempt, 4));
            ui.endMessage();
            ui.note("model request failed ({s}); retry {d}/{d} in {d} s", .{ if (e == error.Status) llm.detail[0..@min(llm.detail_len, 60)] else @errorName(e), attempt + 1, max_retries, secs });
            if (try http.wait(sys.sigfd, @intCast(secs * 1000))) return error.Cancel;
            continue;
        };
        return;
    }
}

/// The server rejected the request for its length (wording differs per server).
fn tooLong() bool {
    const d = llm.detail[0..llm.detail_len];
    for ([_][]const u8{ "context length", "context_length", "maximum context", "too long", "too many tokens", "exceeds" }) |k| {
        if (std.ascii.indexOfIgnoreCase(d, k) != null) return true;
    }
    return false;
}

const compact_instructions =
    \\The conversation below is about to exceed the context window. Write a summary that lets you
    \\continue the task without it. Use exactly these sections:
    \\## Goal
    \\## Constraints & Preferences
    \\## Progress
    \\### Done
    \\### In Progress
    \\### Blocked
    \\## Key Decisions
    \\## Next Steps
    \\## Critical Context
    \\Be concrete: file names, function names, commands, error messages, values. Do not call tools.
    \\
    \\<conversation>
    \\
;

/// One message as plain text for the summary request: "[User]: …", "[Assistant]: …",
/// "[Assistant tool calls]: name(args)", "[Tool result]: …". Long parts are cut.
fn serialize(json: []const u8, fba: std.mem.Allocator, w: *Buf) void {
    const M = struct {
        role: Str,
        content: ?Str = null,
        tool_calls: ?[]const struct { function: struct { name: Str = .{ .v = "" }, arguments: Str = .{ .v = "" } } } = null,
    };
    const m = std.json.parseFromSliceLeaky(M, fba, json, .{ .ignore_unknown_fields = true }) catch return;
    const role = m.role.v;
    const cap: usize = if (std.mem.eql(u8, role, "tool")) 1500 else 4000;
    const label = if (std.mem.eql(u8, role, "user")) "[User]: " else if (std.mem.eql(u8, role, "tool")) "[Tool result]: " else "[Assistant]: ";
    if (m.content) |cs| if (std.mem.trim(u8, cs.v, " \n").len > 0) {
        const c = cs.v;
        w.add(label);
        if (c.len <= cap) w.add(c) else {
            w.add(c[0 .. cap * 2 / 3]);
            w.print("\n[… {d} bytes cut …]\n", .{c.len - cap});
            w.add(c[c.len - cap / 3 ..]);
        }
        w.byte('\n');
    };
    if (m.tool_calls) |calls| {
        w.add("[Assistant tool calls]: ");
        for (calls, 0..) |tc, k| {
            if (k > 0) w.add("; ");
            w.add(tc.function.name.v);
            w.byte('(');
            const args = tc.function.arguments.v;
            w.add(args[0..@min(args.len, 300)]);
            w.byte(')');
        }
        w.byte('\n');
    }
}

/// When the prompt is still over 80% of the window after elision (or the server said it
/// is too long: `force`), summarize and rebuild the history as: first user message,
/// summary + latest checklist + files read/changed, then the newest messages from an
/// assistant message on (so every tool result keeps its call). The summary request is
/// the conversation serialized to text with long tool results cut, so it fits even when
/// the real history no longer does. The session log keeps everything.
fn compact(force: bool) bool {
    if (n_msgs < 4 or n_msgs > max_index) return false;
    if (!force and (ctx_limit == 0 or ctx_tokens * 10 < ctx_limit * 8)) return false;
    ui.note("context {d}k of {d}k: summarizing earlier work to continue", .{ ctx_tokens / 1000, ctx_limit / 1000 });
    const items = msgs.items();
    const msgAt = struct {
        fn f(it: []const u8, i: usize) []const u8 {
            const end = if (i + 1 < n_msgs) offs[i + 1] else it.len;
            return it[offs[i] + 1 .. end];
        }
    }.f;
    var region = Buf.init(256 << 20);
    defer region.free();
    _ = region.extend(0);
    var fba = std.heap.FixedBufferAllocator.init(region.base.?[0..region.cap]);

    // Transcript: message 0 (the task), then as many of the newest messages as fit.
    const budget: usize = if (ctx_limit > 0) @intCast(ctx_limit * 2) else msgs.len / 3; // ~half the window in chars
    var tr = Buf.init(1 << 30);
    defer tr.free();
    var parts = Buf.init(1 << 30); // serialized messages 1.., newest first, sizes in `sizes`
    defer parts.free();
    var first = Buf.init(1 << 24);
    defer first.free();
    serialize(msgAt(items, 0), fba.allocator(), &first);
    var start = n_msgs;
    var used: usize = first.len;
    var tmp = Buf.init(1 << 24);
    defer tmp.free();
    while (start > 1) {
        tmp.reset();
        serialize(msgAt(items, start - 1), fba.allocator(), &tmp);
        if (used + tmp.len > budget) break;
        used += tmp.len;
        start -= 1;
    }
    tr.add(compact_instructions);
    tr.add(first.items());
    if (start > 1) tr.print("[… {d} earlier messages omitted …]\n", .{start - 1});
    for (start..n_msgs) |i| serialize(msgAt(items, i), fba.allocator(), &tr);
    tr.add("</conversation>");
    var req = Buf.init(tr.len * 6 + 128);
    defer req.free();
    req.add(",{\"role\":\"user\",\"content\":");
    bufm.str(&req, tr.items());
    req.add("}],\"tool_choice\":\"none\"}");

    const was_quiet = ui.quiet;
    ui.quiet = true;
    streamRetrying("", req.items()) catch {
        ui.endMessage();
        ui.quiet = was_quiet;
        ui.note("summary request failed; keeping the full history", .{});
        return false;
    };
    ui.endMessage(); // close the hidden message so no stray newline reaches stdout
    ui.quiet = was_quiet;
    const summary = std.mem.trim(u8, turn.content.items(), " \t\r\n");
    if (summary.len < 20 or turn.n > 0) {
        ui.note("no usable summary; keeping the full history", .{});
        return false;
    }
    // Latest checklist, unescaped from its tool message.
    var todo_text: []const u8 = "";
    var i = n_msgs;
    while (i > 0) {
        i -= 1;
        const m = msgAt(items, i);
        if (std.mem.indexOf(u8, m[0..@min(m.len, 200)], "\"content\":\"" ++ tools.todo_marker) == null) continue;
        const T = struct { content: Str };
        if (std.json.parseFromSliceLeaky(T, fba.allocator(), m, .{ .ignore_unknown_fields = true })) |t| todo_text = t.content.v else |_| {}
        break;
    }
    // Keep the newest ~25% of the window (or of the current history when the window is unknown).
    const keep_bytes: usize = if (ctx_limit > 0) @intCast(ctx_limit) else msgs.len / 4;
    var k = n_msgs;
    var kept: usize = 0;
    while (k > 1) {
        const m = msgAt(items, k - 1);
        if (kept + m.len > keep_bytes) break;
        kept += m.len + 1;
        k -= 1;
    }
    while (k < n_msgs and !std.mem.startsWith(u8, msgAt(items, k), "{\"role\":\"assistant\"")) k += 1;
    // The summary message.
    var text = Buf.init(summary.len + todo_text.len + 32 * 1024);
    defer text.free();
    text.add("[Earlier work, summarized because the context filled up]\n");
    text.add(summary);
    if (todo_text.len > 0) {
        text.add("\n\n");
        text.add(todo_text);
    }
    if (tools.files_read.n > 0) {
        text.add("\n\n<read-files>\n");
        tools.files_read.list(&text);
        text.add("</read-files>");
    }
    if (tools.files_changed.n > 0) {
        text.add("\n<modified-files>\n");
        tools.files_changed.list(&text);
        text.add("</modified-files>");
    }
    var sm = Buf.init(text.len * 6 + 64);
    defer sm.free();
    sm.add("{\"role\":\"user\",\"content\":");
    bufm.str(&sm, text.items());
    sm.byte('}');
    // Rebuild: copy the old messages and offsets first, since offs is rewritten.
    var copy = Buf.init(msgs.len + 16);
    defer copy.free();
    copy.add(items);
    var old_offs = Buf.init((n_msgs + 1) * @sizeOf(usize));
    defer old_offs.free();
    old_offs.add(std.mem.sliceAsBytes(offs[0..n_msgs]));
    const oo = std.mem.bytesAsSlice(usize, @as([]align(1) u8, old_offs.items()));
    var nb = Buf.init(msgs.cap);
    var noffs: usize = 0;
    offs[noffs] = nb.len;
    noffs += 1;
    nb.byte(',');
    nb.add(copy.items()[oo[0] + 1 .. if (n_msgs > 1) oo[1] else copy.len]);
    offs[noffs] = nb.len;
    noffs += 1;
    nb.byte(',');
    nb.add(sm.items());
    var j = k;
    while (j < n_msgs) : (j += 1) {
        const e = if (j + 1 < n_msgs) oo[j + 1] else copy.len;
        offs[noffs] = nb.len;
        noffs += 1;
        nb.add(copy.items()[oo[j]..e]);
    }
    const dropped = k - 1;
    const before = msgs.len;
    msgs.free();
    msgs = nb;
    n_msgs = noffs;
    ctx_tokens = if (before > 0) ctx_tokens * msgs.len / before else 0;
    session.append(sm.items());
    ui.note("compacted: {d} older messages replaced by a summary (~{d}k tokens now)", .{ dropped, ctx_tokens / 1000 });
    return true;
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
