const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const http = @import("http.zig");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const ui = @import("ui.zig");
const agent = @import("agent.zig");
const session = @import("session.zig");
const tui = @import("tui.zig");
const bufm = @import("buf.zig");
const agents = @import("agents.zig");
const summary = @import("summary.zig");

const build_options = @import("build_options");
pub const version = build_options.version;
/// "0.1.0 (8d7c9ae)": the version and the commit this binary was built from.
pub const version_line = version ++ " (" ++ build_options.commit[0..@min(7, build_options.commit.len)] ++ ")";

// Release builds drop std's stack-trace machinery (DWARF, ELF, Io): it was most of the binary.
pub const panic = if (@import("builtin").mode == .Debug) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.FullPanic(shortPanic);
pub const std_options: std.Options = .{ .enable_segfault_handler = false, .signal_stack_size = null };
fn shortPanic(msg: []const u8, _: ?usize) noreturn {
    tui.restore();
    sys.writeAll(sys.stderr, "awl: panic: ") catch {};
    sys.writeAll(sys.stderr, msg) catch {};
    sys.writeAll(sys.stderr, "\n") catch {};
    sys.exit(134);
}

const usage =
    \\usage: awl [-p PROMPT] [-c | -r FILE] [--full]
    \\  -p PROMPT   run once and print the reply (no TUI)
    \\  -c          continue the latest session started in this directory
    \\  -r FILE     resume a session file
    \\  --full      full-screen mode (also AWL_FULL=1, or /full)
    \\  --bg        with -p: run as a background agent (the TUI's ← view starts these)
    \\  --version   print "awl VERSION (COMMIT)": the build's version and git commit
    \\env: AWL_URL (http:// or https://, name or address) AWL_CA_FILE (PEM bundle for https)
    \\     AWL_MODEL AWL_KEY AWL_MODE AWL_REASONING AWL_MAX_TOKENS AWL_MAX_STEPS
    \\     AWL_RETRIES AWL_TIMEOUT (s without data from the model, default 600; 0: none)
    \\     AWL_CTX (context window in tokens, when the server does not report it) AWL_SYSTEM
    \\     AWL_AGENTS (off) AWL_WELCOME (off: one line)
    \\     AWL_MODELS (Ctrl-P cycles) AWL_STATUS (model,ctx,mode,branch,dir,session,agents or off)
    \\     AWL_SANDBOX (off: no sandbox) AWL_SANDBOX_NET (on: every command gets the network) AWL_SANDBOX_WRITE=dir:dir
    \\     AWL_NETWORK (off: refuse commands that ask for the network, without asking anyone)
    \\     AWL_SANDBOX_SOCKETS=path:path (sockets under /tmp that commands may still reach)
    \\     AWL_SUMMARY=FILE (with -p: write a JSON summary of the run there; docs/embedding.md)
    \\     AWL_THINK_BUDGET=N (SGLang --enable-strict-thinking: cap reasoning per reply)
    \\     AWL_THINK_MAX=N (any server: stop a reply that thinks past N tokens, then act)
    \\     AWL_THINKING (off: ask the chat template for no thinking on every request)
    \\     AWL_KEEP_REASONING (N: send only the newest N turns' reasoning back; 0: none)
    \\     AWL_THINK_ROWS (reasoning rows shown live, default 6; 0: timer only)
    \\     AWL_BATCH (1: ask the model to make independent tool calls in one reply; arena A/B)
    \\     AWL_ROOTCAUSE (0: leave out the system prompt line asking for root-cause fixes that cover every instance)
    \\     AWL_CTX_MODE (fresh: fresh context + session view when the window fills; compact: a summary)
    \\     AWL_DEBUG_KEYS=FILE (log raw input, escaped: for keyboard / paste problems)
    \\     AWL_TITLE (off: leave the terminal title alone) NO_COLOR (any value: no colors)
    \\
;

/// A numeric setting: unset gives `default`; anything but a whole number is exit 2.
fn num(comptime name: []const u8, comptime T: type, default: T) T {
    const s = sys.getenv(name) orelse return default;
    return std.fmt.parseInt(T, s, 10) catch die(name ++ " must be a whole number, not \"{s}\"", .{s});
}

fn die(comptime f: []const u8, a: anytype) noreturn {
    ui.err(f, a);
    summary.write(.error_, 2, session.path, &tools.files_changed, version_line);
    sys.exit(2);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    tui.bigBuffersLazy();
    sys.envp = @ptrCast(init.environ.block.slice);
    const argv = init.args.vector;

    var prompt: ?[]const u8 = null;
    var resume_path: ?[]const u8 = null;
    var cont = false;
    var idle = false;
    var bg = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        const eq = std.mem.eql;
        if (eq(u8, a, "--version")) {
            sys.writeAll(sys.stdout, "awl " ++ version_line ++ "\n") catch {};
            return 0;
        } else if (eq(u8, a, "-p") and i + 1 < argv.len) {
            i += 1;
            prompt = std.mem.span(argv[i]);
        } else if (eq(u8, a, "-r") and i + 1 < argv.len) {
            i += 1;
            resume_path = std.mem.span(argv[i]);
        } else if (eq(u8, a, "-c")) {
            cont = true;
        } else if (eq(u8, a, "--full")) {
            tui.start_full = true;
        } else if (eq(u8, a, "--bg")) {
            bg = true;
        } else if (eq(u8, a, "--idle-rss")) {
            idle = true;
        } else if (eq(u8, a, "-h") or eq(u8, a, "--help")) {
            sys.writeAll(sys.stdout, usage) catch {};
            return 0;
        } else {
            sys.writeAll(sys.stderr, usage) catch {};
            return 2;
        }
    }
    if ((cont and resume_path != null) or (prompt != null and prompt.?.len == 0)) { // -c with -r; an empty prompt
        sys.writeAll(sys.stderr, usage) catch {};
        return 2;
    }

    if (bg and prompt == null) {
        sys.writeAll(sys.stderr, usage) catch {};
        return 2;
    }
    if (prompt != null and !bg) summary.path = sys.getenv("AWL_SUMMARY");
    sys.setupSignals();
    tools.detect();
    ui.oneshot = prompt != null;
    agents.enabled = prompt == null or bg; // plain -p (scripts, benchmarks) leaves no status file
    agents.kind = if (bg) .bg else .tui;
    ui.color = !ui.oneshot and sys.isatty(sys.stdout);
    // no-color.org: any non-empty NO_COLOR turns hues off.
    ui.no_color = if (sys.getenv("NO_COLOR")) |v| v.len > 0 else false;
    ui.loadTheme();

    var cwd_b: [4096]u8 = undefined;
    const cwd_rc = linux.getcwd(&cwd_b, cwd_b.len);
    const cwd = if (linux.errno(cwd_rc) == .SUCCESS) std.mem.sliceTo(&cwd_b, 0) else ".";
    @import("sandbox.zig").setup(agent.projectRoot(cwd));

    agent.cfg = .{ .url = http.parseUrl(sys.getenv("AWL_URL") orelse "http://127.0.0.1:12434") catch die("AWL_URL must look like http://127.0.0.1:12434 or https://host/prefix", .{}) };
    http.resolve(&agent.cfg.url) catch die("cannot resolve {s} (checked /etc/hosts and the resolv.conf nameservers)", .{agent.cfg.url.name});
    var key_b: [512]u8 = undefined;
    agent.cfg.key = sys.getenv("AWL_KEY") orelse gatewayKey(&key_b);
    // Numeric settings: a value that is not a whole number is a mistake, not a default (exit 2,
    // like a bad AWL_MODE), so an embedder's typo cannot run 200 steps or 65536 tokens unnoticed.
    llm.think_max = 4 * num("AWL_THINK_MAX", usize, 0);
    agent.max_steps = num("AWL_MAX_STEPS", usize, 200);
    if (agent.max_steps == 0) die("AWL_MAX_STEPS must be at least 1", .{});
    agent.max_retries = num("AWL_RETRIES", u32, 5);
    _ = num("AWL_MAX_TOKENS", u32, 65536); // agent.zig reads it again (0: no cap)
    _ = num("AWL_THINK_BUDGET", u32, 0); // agent.zig reads it again
    const timeout_s = num("AWL_TIMEOUT", u32, 600);
    http.idle_ms = if (timeout_s == 0) -1 else @intCast(@min(timeout_s, 2_000_000) * 1000);
    tui.keylog_path = sys.getenv("AWL_DEBUG_KEYS");
    if (sys.getenv("AWL_THINKING")) |s| agent.thinking = !std.mem.eql(u8, s, "off");
    agent.keep_reasoning = if (sys.getenv("AWL_KEEP_REASONING")) |s| (if (std.mem.eql(u8, s, "off")) 0 else if (std.mem.eql(u8, s, "on")) std.math.maxInt(usize) else num("AWL_KEEP_REASONING", usize, 0)) else std.math.maxInt(usize);
    ui.think_rows = @min(num("AWL_THINK_ROWS", usize, 6), 64);
    if (sys.getenv("AWL_FULL")) |s| tui.start_full = tui.start_full or std.mem.eql(u8, s, "1");
    if (sys.getenv("AWL_MODE")) |s| tools.mode = std.meta.stringToEnum(tools.Mode, s) orelse die("AWL_MODE must be auto, ask or plan", .{});

    if (idle) { // budget probe: full startup minus the network
        agent.cfg.model = "idle";
        agent.init(cwd);
        var b: [32]u8 = undefined;
        sys.writeAll(sys.stdout, std.fmt.bufPrint(&b, "{d}\n", .{sys.peakRssKb()}) catch "0\n") catch {};
        return 0;
    }

    var model_b: [256]u8 = undefined;
    const info: ?llm.ModelInfo = llm.pickModel(agent.cfg, sys.getenv("AWL_MODEL"), &model_b) catch |e| switch (e) {
        error.Tls => die("TLS to {s} failed: {s}. AWL_CA_FILE=path points at another CA bundle.", .{ agent.cfg.url.host, @import("tls.zig").detail }),
        else => null,
    };
    agent.cfg.model = sys.getenv("AWL_MODEL") orelse if (info) |m| m.id else die("no model at {s}. Start one with Omarchy Local AI, or set AWL_URL / AWL_MODEL.", .{agent.cfg.url.host});
    if (info) |m| agent.ctx_limit = m.ctx;
    const ctx_override = num("AWL_CTX", u64, 0); // the server did not say, or said it for another model
    if (ctx_override > 0) agent.ctx_limit = ctx_override;
    agent.init(cwd);
    defer tools.killJobs(); // background jobs never outlive awl
    ui.cwd = cwd; // main's buffer lives as long as the program

    {
        var w = bufm.Buf.init(8192);
        defer w.free();
        w.add("{\"awl\":\"" ++ version ++ "\",\"model\":");
        bufm.str(&w, agent.cfg.model);
        w.add(",\"cwd\":");
        bufm.str(&w, cwd);
        w.byte('}');
        const k = @min(w.len, session.meta_b.len);
        @memcpy(session.meta_b[0..k], w.items()[0..k]);
        session.start_meta = session.meta_b[0..k];
        const c = @min(cwd.len, session.cwd_b.len);
        @memcpy(session.cwd_b[0..c], cwd[0..c]);
        session.start_cwd = session.cwd_b[0..c];
    }
    var latest_b: [512]u8 = undefined;
    if (cont) { // the newest session started in this directory
        var one: [1]session.Entry = undefined;
        const l = session.list(cwd, &one);
        if (l.len == 0) die("no saved sessions for {s}", .{cwd});
        resume_path = session.pathOf(&l[0], &latest_b) orelse die("no saved sessions", .{});
    }
    if (resume_path) |p| {
        if (agents.busyElsewhere(p)) |o| die("that session is in use by another awl (pid {d}{s}); open awl and press ← to see it", .{ o.pid, if (o.kind == .bg) ", a background agent" else "" });
        const n = agent.resume_(p) catch die("cannot read session {s}", .{p});
        if (!ui.oneshot) ui.note("resumed {d} messages from {s}", .{ n, p });
    } else {
        session.create(session.start_meta);
    }
    defer session.dropView(); // the view is a copy for this run; the session file stays

    if (bg) return background(prompt.?);
    if (prompt) |p| {
        agent.user(p);
        const o = agent.run();
        const rc: u8 = switch (o) {
            .done => 0,
            .cancelled => 130,
            else => 1,
        };
        summary.write(switch (o) {
            .done => .done,
            .cancelled => .cancelled,
            .failed => .error_,
            .max_steps => .step_limit,
        }, rc, session.path, &tools.files_changed, version_line);
        if (sys.getenv("AWL_RSS") != null) { // budget probe: peak RSS of this process
            var b: [48]u8 = undefined;
            sys.writeAll(sys.stderr, std.fmt.bufPrint(&b, "peak_rss_kb {d}\n", .{sys.peakRssKb()}) catch "") catch {};
        }
        return rc;
    }
    defer session.close(); // a TUI's status file goes with it
    return tui.repl();
}

/// --bg: a background agent. Messages sent to it meanwhile (its inbox) run as follow-ups;
/// questions wait for an answer from the dashboard; SIGINT stops it.
fn background(prompt: []const u8) u8 {
    tools.ask = &agents.bgAsk;
    agent.steer = &agents.bgSteer;
    agent.user(prompt);
    var o = agent.run();
    while (o == .done) {
        const more = agents.bgSteer() orelse break;
        agent.user(more);
        o = agent.run();
    }
    agents.set(switch (o) {
        .done => .done,
        .cancelled => .stopped,
        else => .failed,
    });
    agents.notify(switch (o) {
        .done => "finished",
        .cancelled => "stopped",
        else => "failed",
    });
    session.close();
    return switch (o) {
        .done => 0,
        .cancelled => 130,
        else => 1,
    };
}

/// Omarchy Local AI keeps its gateway key here.
fn gatewayKey(buf: []u8) ?[]const u8 {
    const home = sys.getenv("HOME") orelse return null;
    var pb: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/.local/state/omarchy/local-ai/gateway.key", .{home}) catch return null;
    const k = std.mem.trim(u8, sys.readFile(p, buf) catch return null, " \r\n\t");
    return if (k.len > 0) k else null;
}

test {
    _ = @import("buf.zig");
    _ = @import("http.zig");
    _ = @import("llm.zig");
    _ = @import("sys.zig");
    _ = @import("skills.zig");
    _ = @import("tools.zig");
    _ = @import("undo.zig");
    _ = @import("jint.zig");
    _ = @import("session.zig");
    _ = @import("tui.zig");
    _ = @import("screen.zig");
    _ = @import("sandbox.zig");
    _ = @import("agent.zig");
    _ = @import("ui.zig");
    _ = @import("agents.zig");
    _ = @import("dash.zig");
    _ = @import("prompts.zig");
    _ = @import("dns.zig");
    _ = @import("tls.zig");
    _ = @import("summary.zig");
}
