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

pub const version = "0.1.0";

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
    \\  -c          continue the latest session
    \\  -r FILE     resume a session file
    \\  --full      full-screen mode (also AWL_FULL=1, or /full)
    \\env: AWL_URL AWL_MODEL AWL_KEY AWL_MAX_STEPS AWL_SYSTEM AWL_REASONING AWL_RETRIES AWL_MODE
    \\     AWL_STATUS (model,ctx,mode,branch,dir,session or off) AWL_WELCOME (off: one line) AWL_MODELS (Ctrl-P cycles)
    \\
;

fn die(comptime f: []const u8, a: anytype) noreturn {
    ui.err(f, a);
    sys.exit(2);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.envp = @ptrCast(init.environ.block.slice);
    const argv = init.args.vector;

    var prompt: ?[]const u8 = null;
    var resume_path: ?[]const u8 = null;
    var cont = false;
    var idle = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        const eq = std.mem.eql;
        if (eq(u8, a, "--version")) {
            sys.writeAll(sys.stdout, "awl " ++ version ++ "\n") catch {};
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
        } else if (eq(u8, a, "--idle-rss")) {
            idle = true;
        } else {
            sys.writeAll(sys.stderr, usage) catch {};
            return if (eq(u8, a, "-h") or eq(u8, a, "--help")) 0 else 2;
        }
    }

    sys.setupSignals();
    tools.detect();
    ui.oneshot = prompt != null;
    ui.color = !ui.oneshot and sys.isatty(sys.stdout);
    ui.loadTheme();

    var cwd_b: [4096]u8 = undefined;
    const cwd_rc = linux.getcwd(&cwd_b, cwd_b.len);
    const cwd = if (linux.errno(cwd_rc) == .SUCCESS) std.mem.sliceTo(&cwd_b, 0) else ".";

    agent.cfg = .{ .url = http.parseUrl(sys.getenv("AWL_URL") orelse "http://127.0.0.1:12434") catch die("AWL_URL must look like http://127.0.0.1:12434", .{}) };
    var key_b: [512]u8 = undefined;
    agent.cfg.key = sys.getenv("AWL_KEY") orelse gatewayKey(&key_b);
    if (sys.getenv("AWL_MAX_STEPS")) |s| agent.max_steps = std.fmt.parseInt(usize, s, 10) catch 200;
    if (sys.getenv("AWL_RETRIES")) |s| agent.max_retries = std.fmt.parseInt(u32, s, 10) catch 5;
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
    const info: ?llm.ModelInfo = llm.firstModel(agent.cfg, &model_b) catch null;
    agent.cfg.model = sys.getenv("AWL_MODEL") orelse if (info) |m| m.id else
        die("no model at {s}. Start one with Omarchy Local AI, or set AWL_URL / AWL_MODEL.", .{agent.cfg.url.host});
    if (info) |m| agent.ctx_limit = m.ctx;
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
        const n = agent.resume_(p) catch die("cannot read session {s}", .{p});
        if (!ui.oneshot) ui.note("resumed {d} messages from {s}", .{ n, p });
    } else {
        session.create(session.start_meta);
    }

    if (prompt) |p| {
        agent.user(p);
        const rc: u8 = switch (agent.run()) {
            .done => 0,
            .cancelled => 130,
            else => 1,
        };
        if (sys.getenv("AWL_RSS") != null) { // budget probe: peak RSS of this process
            var b: [48]u8 = undefined;
            sys.writeAll(sys.stderr, std.fmt.bufPrint(&b, "peak_rss_kb {d}\n", .{sys.peakRssKb()}) catch "") catch {};
        }
        return rc;
    }
    return tui.repl();
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
}
