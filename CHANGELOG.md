# Changelog

Releases are tags `vX.Y.Z` on `main`; each attaches `awl-linux-x86_64`, `awl-linux-aarch64` and
`SHA256SUMS` (docs/releasing.md). Before 1.0 a minor bump may break the embedding contract
(docs/embedding.md); a patch release never does.

## v0.1.0 (2026-11-02)

The first release: everything from the v1 build order (PLAN.md) plus the October arena work.

**The agent**
- One static binary (no libc) for x86_64 and aarch64 Linux; `--version` names the build.
- Seven tools: read, write, edit (one change or an `edits` list, all or nothing), bash (timeouts,
  background jobs; a command still running at its timeout becomes a job instead of being killed),
  grep (ripgrep), find (fd), todo.
- Any OpenAI-compatible server, `http://` or `https://` (TLS and DNS in the binary), with a key.
- Context handling: old tool output elided from 60% of the window, a summary at 80% (`compact`),
  or a fresh context with a session view (`AWL_CTX_MODE=fresh`, measured in the arena).
- Reasoning sent back with its turn; `AWL_KEEP_REASONING=N` keeps a window; `AWL_THINK_MAX`,
  `AWL_THINK_BUDGET`, `AWL_THINKING=off` for engines that think too long.
- Retries with backoff on transient model errors; `max_tokens` sized to the window.

**Safety**
- The model's commands run in one bubblewrap sandbox per session: read-only filesystem except the
  project, `/tmp`, build caches and `AWL_SANDBOX_WRITE`; secrets, `/run/user`, sockets under
  `/tmp`, other processes and most environment variables hidden; no nested user namespaces.
- No network unless a person says yes to one command (`network: true`); `AWL_NETWORK=off` refuses
  without asking; `AWL_SANDBOX_SOCKETS` names sockets commands may keep.
- `.git/config`, `.git/hooks`, `AGENTS.md`, `.agents/` are read-only to commands and guarded for
  edits. `/undo` and `/rewind` put files back.

**The TUI**
- Inline (scrollback kept) or full-screen; streaming markdown-lite with aligned tables, code
  blocks, clickable links; diffs for edits; a live reasoning view and timer; a pinned checklist.
- Queue messages while the model works; `@file`, `!cmd`, prompt commands, `/diff`, `/copy`,
  `/resume`, Ctrl-R history, Ctrl-G editor, pickers, Omarchy theme colors, `NO_COLOR`.
- The agents & sessions view (←): background agents (`awl --bg`, `/bg`), steering, approvals,
  fork, rename, search.

**For programs that run awl** (docs/embedding.md)
- `awl -p` never asks; stable exit statuses; the session file format; stable openings for every
  tool-result refusal.
- `AWL_SUMMARY=FILE`: one JSON object per run (status, exit, steps, tool calls, each command's
  outcome, files written).

**Dev loop**
- `zig build lint | test | check | e2e | sandbox | release`; reproducible release builds checked
  on two runners; the arena (`arena/`) and Terminal-Bench through Harbor.
