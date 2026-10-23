# `awl`: a bare-metal coding-agent harness + TUI for Omarchy Linux

## Context
`nib` (github.com/AstralDrift/nib, private) is your macOS-native C harness: one small binary, 4 tools, a raw-socket SSE client, strict memory budgets, and an "arena" that benchmarks it against other harnesses. You want the Omarchy Linux sibling, built for this desktop (RTX 4090, Omarchy Local AI gateway) and compared head-to-head against pi, omp, and grok on the same model (Qwen3.8-27B EXL3).

Name: **`awl`**, a small pointed tool like a nib. The name is free on this machine and on your GitHub account.

Differences from nib: written in **Zig** (your choice), Linux only (epoll and raw syscalls, no libc), and it ships a **minimal inline TUI**. Search goes through **ripgrep/fd** instead of shelling out through bash.

## Hard constraints
- **Language:** Zig 0.16.0 (`pacman -S zig`), pinned in `build.zig.zon` (`minimum_zig_version`). Target `x86_64-linux-none`, so it is static with **no libc**. `-OReleaseSmall`, stripped, `-mcpu=native` for local builds.
- **Dependencies:** the Zig std lib only. Use `std.os.linux` syscalls directly where the std abstractions allocate or add layers. No `std.http`: localhost needs no TLS, so a raw socket is enough.
- **Model link:** OpenAI-compatible `POST /v1/chat/completions`, `stream:true`, HTTP/1.1 over a raw TCP socket to the Omarchy Local AI gateway at `http://127.0.0.1:12434`. Bearer key from `~/.local/state/omarchy/local-ai/gateway.key`. The model defaults to the first id from `GET /v1/models`, so awl follows whichever deploy is live.
- **Budgets** (asserted by `make`-style `zig build check`):
  - Binary ≤ 200 KB stripped.
  - Idle RSS ≤ 1.5 MB. Peak RSS ≤ 8 MB over a scripted 50-turn session, not counting tool-output bytes. Measured from `VmHWM` in `/proc/<pid>/status`.
  - Cold start to prompt ≤ 3 ms (`hyperfine`).
  - About 0% CPU while waiting: one blocking `epoll_wait` and no polling.
- **KISS:** about 3,000 lines of Zig for v1, TUI included.

## v1 scope (exactly this)
1. **Agent loop:** user message → model → tool calls → results → model, until a turn has no tool calls. `max_steps` defaults to 50.
2. **Six tools:**
   - `read(path, offset?, limit?)`: `mmap`, line-numbered, capped at 2,000 lines / 64 KB.
   - `write(path, content)`: atomic, temp file + `rename`.
   - `edit(path, old, new)`: exact unique replace. Fails loudly on 0 or 2+ matches.
   - `bash(command, timeout_s?)`: `vfork`+`execve` of `/bin/bash -c` in a new process group. Pipes are read via epoll, output keeps head+tail within 64 KB, and the whole group is killed on timeout (default 120 s).
   - `grep(pattern, path?, glob?)`: runs `/usr/bin/rg -n --no-heading --color never --max-columns 300` directly (argv, no shell) and caps results at 200 lines / 32 KB.
   - `find(pattern?, path?)`: runs `/usr/bin/fd --color never` the same way, capped at 500 entries.
   - If `rg` or `fd` is missing, the tool is not offered to the model. awl does not fall back to bash.
3. **Inline TUI** (no alternate screen, so the terminal's own scrollback and selection keep working):
   - Raw mode only while editing the prompt line. Multi-line input with Alt-Enter, Up/Down for history, Ctrl-C/Ctrl-D.
   - Assistant tokens stream as they arrive. Qwen `reasoning_content` is shown dimmed and collapsed to one line once the answer starts. Tool calls appear as one accent-colored line (`▸ grep "foo" src/`), with output previewed in at most 8 dim lines.
   - One status line: model, tok/s, context used/limit, harness RSS.
   - **Omarchy theme:** colors come from `~/.local/state/omarchy/current/theme/colors.toml` (accent, foreground, muted, red, green, yellow) as 24-bit SGR. They are re-read on `/theme`. A tiny `~/.config/omarchy/hooks/theme-set.d/awl` hook is in Later.
   - Markdown: only code fences get colored. No other rendering.
   - When stdout is not a TTY, the output is plain text.
4. **Interrupt:** the first Ctrl-C aborts the in-flight request or tool (closes the socket or kills the process group) and the prompt survives. A second Ctrl-C at an idle prompt exits. A signalfd is part of the epoll set.
5. **Sessions:** JSONL append to `~/.local/state/awl/sessions/<ts>.jsonl`. `awl -r <file>` resumes, `awl -c` continues the latest.
6. **Config:** env only: `AWL_URL`, `AWL_MODEL`, `AWL_KEY`, `AWL_MAX_STEPS`, `AWL_SYSTEM`. No config file.
7. **System prompt:** under 1 KB, embedded. It names the 6 tools and the cwd, and appends `AGENTS.md` from the cwd and from the git root if present.
8. **One-shot:** `awl -p "<prompt>"` runs to completion with no TUI and exits 0. The arena needs this.
9. Slash commands: `/clear`, `/quit`, `/theme` only.

**Out of v1:** compaction, MCP, sub-agents, permission prompts, multiple providers, TLS, images, plugins, config file, full markdown.

## Architecture
```
build.zig  build.zig.zon
src/
  main.zig     args, env, signalfd + epoll setup, mode switch (tui | -p)
  mem.zig      two arenas: per-turn (reset after each model call) + session
  http.zig     connect, request write, chunked/Content-Length read, SSE "data:" lines
  json.zig     request writer with escaping; streaming delta parse via std.json.Scanner (no DOM)
  llm.zig      message list → request; accumulate content / reasoning / tool_calls by index
  tools.zig    6 tools + static schema JSON; spawn.zig-free: vfork/execve/epoll inline
  tui.zig      raw mode, line editor, stream renderer, status line, theme loader
  session.zig  JSONL append/load
  agent.zig    the loop
tests/
  fake_sse.py  stdlib replay server (recorded streams, incl. split UTF-8 / split tool_call JSON)
  *.sh         per-phase checks; check.sh = all budgets
arena/         benchmark rig (outside the line budget; Python stdlib + shell)
```
Memory model as in nib: no per-object alloc in the hot path, a fixed 16 KB socket buffer, tool output truncated before it is stored, and one request buffer that is reused and never shrunk.

## Arena (head-to-head on Qwen3.8-27B EXL3)
- Reuse what exists in `~/Work/local-ai-harness-bench`:
  - The adapter invocations for omp, pi, grok (and codex) in `run-round4.sh`, with configs under `~/.local/state/omarchy/local-ai/bench-agents`. Keys stay out of the repo.
  - The `fixture/` ledger bug task and `score.py`. Copy both into `arena/tasks/ledger/` as the first task.
- `arena/proxy.py` sits between every harness and the gateway. Per run it logs prompt, completion, and cached tokens, bytes sent, turns, tool calls, and model time vs harness time.
- Tiers:
  - **T0** replays recorded streams through fake_sse with no GPU, in under 10 s.
  - **T1** is 5 tiny tasks, about 3 min.
  - **T2** is about 15 tasks × 3 runs, about 15 min, across `awl pi omp grok`.
- The harness's peak RSS (process tree) is sampled from `/proc`. `arena/report.py` prints the table and the delta against `arena/baseline.json`.
- One model at a time: the arena checks `GET /v1/models` first and stops with a clear error if Local AI has no deploy ready.

## Build order (each phase passes its check before the next)
0. **Repo + backup:** `~/Work/awl`, `git init`, a `gh repo create AstralDrift/awl --private` remote, plus README, AGENTS.md (project rules from this plan), and `.gitignore`. *Check:* the first push succeeds.
1. **Skeleton:** build.zig, `mem`, `--version`. *Check:* static (`file awl` says statically linked), ≤ 200 KB, idle RSS ≤ 1.5 MB.
2. **HTTP + SSE:** stream a hard-coded chat to fake_sse and to the live gateway. *Check:* chunked encoding, `[DONE]`, and split chunks pass.
3. **JSON + tool_call accumulation.** *Check:* unit tests (`zig build test`) on canned transcripts with split UTF-8 and split arguments.
4. **Tools.** *Check:* one test per tool for success, missing file, non-unique edit, timeout killing a grandchild, truncation, and rg/fd caps.
5. **Agent loop + `-p`.** *Check:* the ledger fixture passes `score.py` with the live Qwen3.8-27B.
6. **TUI + interrupt + sessions.** *Check:* Ctrl-C during `sleep 100` returns to the prompt in under 100 ms, resume works, and theme colors match colors.toml.
7. **Budget pass:** `zig build check` asserts every budget, and the suite runs in Debug (safety checks on).
8. **Arena:** proxy, adapters, tasks, report. *Check:* `arena/run.sh t2 "awl pi omp grok"` prints the scoreboard.

## Backup / sync
I commit after each green phase (the commit message carries the measured size, RSS, and startup) and push to the private `AstralDrift/awl` repo right after. You asked for backup and sync, so the push needs no separate ask. No force pushes. Gateway keys, session logs, and `arena/results/` raw transcripts are gitignored.

## Verification
- `zig build test`: unit tests.
- `tests/*.sh` against fake_sse: loop, tools, interrupt, resume, with no GPU.
- `zig build check`: size, static linkage, idle and peak RSS (`VmHWM`), `hyperfine 'awl --version'` ≤ 3 ms.
- Live: `awl -p` on the ledger fixture with Qwen3.8-27B through Local AI, scored by `score.py`.
- Comparative: arena T2 across awl, pi, omp, and grok, reporting success rate, turns, prompt tokens, wall time, and harness RSS.

## Later
Done since v1: compaction, a permission gate (`AWL_MODE=ask`), the live Omarchy theme, and `/model`.
Still open: an Omarchy Local AI agent entry (`local-ai/agents/awl`) and MCP.

---

## v1.x: iterating toward the best bare-bones harness (2026-10-21)

The v1 build order is done. From here the arena decides. The model is "Arch Linux for agents":
a minimal base that gets real work done and is easy to build on.

**North star:** on arena T2 with Qwen3.8-27B, awl's pass rate is at least the best of
pi / omp / grok, with the fewest prompt tokens and the smallest footprint.

**Footprint goals (soft, not caps):** binary < 256 KB, idle RSS < 1 MB, peak < 4 MB over
50 turns, startup < 1 ms. A feature that wins tasks may spend some of this; one that does
not, does not ship.

**Loop:** hypothesis → change → `arena/run.py t0` (seconds) → T1 → T2 when promising →
record the line in `arena/LOG.md` → keep or revert.

**Backlog (ordered by expected impact; reorder from arena evidence):**
1. Context limit awareness: read `max_model_len` from `/v1/models`, show ctx used/limit,
   and elide old tool outputs before the window fills (no LLM summarisation).
2. `bash` returns when the command exits even if a background job holds the pipe (done: pidfd).
3. Replies start flush: drop leading blank lines from the model (done).
4. Tool-error hints that steer a small model back on track (edit near-miss: show the closest line).
5. Anything the T1/T2 failure logs point at.

Items 1-4 are done (2026-10-22). **External yardstick (2026-10-23):** Terminal-Bench 2.0
through Harbor (`arena/tb.sh`), 20-task subset, against Terminus 2, mini-swe-agent and pi
on the same model and settings. Failure logs from it feed this backlog (first find: replies
need an output cap, `AWL_MAX_TOKENS`).
