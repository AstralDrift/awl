# Harness study: pi 1.4.0 and Grok Build 1.0.62 vs awl (2026-10-21)

Sources:
- **The exact first request each harness sends**, captured offline by pointing it at `tests/fake_sse.py`.
- **Proxy logs** from T3 runs.
- **pi's `docs/`**, especially `compaction.md`.
- **Grok Build's user guide** (`~/.grok/docs/user-guide`, 27 pages).

## What each one sends the model

| | awl | pi | Grok Build |
|---|---|---|---|
| System prompt | ~0.5 KB + AGENTS.md + skills index | ~4.5 KB rules + docs index + skills index | ~5 KB policy (dangerous actions, work policy, background tasks, scratch files, communication, browser checks) |
| Tools | 7 (read, write, edit, bash, todo, grep, find) | 4 (read, bash, edit, write) | 25 (terminal, read_file, search_replace, write, list_dir, grep, todo_write, background output/kill, subagents, scheduler, monitor, plan mode, MCP search/use, image/video gen, …) |
| Request size, first turn | ~3 KB | ~9 KB | ~58 KB |
| Extra requests | none | none | a "dashboard line" summary after replies (adds wall time) |
| `max_completion_tokens` | unset | 8192 (failed impl-spec once by hitting it) | unset |

## Tool behavior

| | awl | pi | Grok Build |
|---|---|---|---|
| read output | every line numbered | no numbers; 2000 lines / 50 KB | `N→` on the first and every 10th line only; 1000 lines; SKILL.md / AGENTS.md always whole |
| bash output cap | first 32 KB + last 32 KB, middle dropped | last 2000 lines / 50 KB; **full output saved to a temp file** | over 20K chars the middle is cut; **full output saved to a log file**, path returned |
| long commands | blocks until done or timeout (120 s) | blocks, no default timeout | `block_until_ms`: still running after it → moves to background with a task id; get output / kill tools; servers start with 0 |
| grep | pattern, path, glob | via bash | pattern, path, glob, **-A/-B/-C context, -i, type, head_limit, multiline**; grouped by file |
| edit | old/new or `edits[]`, all or nothing, closest-line hint | `edits[]` only, prompt explains small unique oldText and merging | old/new, **`replace_all`**, empty old_string creates a file |
| todo | whole list, never elided | none (skills only) | `todo_write` with merge mode, shown live |

## Long sessions

| | awl | pi | Grok Build |
|---|---|---|---|
| Trimming | old tool outputs at 60% | context-edit omissions | (not documented) |
| Compaction | at 80% or on "too long": model summary + checklist + newest ~25% of window | at window − 16K: **structured summary** (Goal, Constraints, Progress done/in-progress/blocked, Key Decisions, Next Steps, Critical Context) + **harness-tracked read/modified file lists**; conversation serialized to text for the summary request; keeps newest 20K tokens; previous summary feeds the next | auto-compact near the window, `/compact`, saved checkpoints |
| Overflow recovery | one forced compaction, then retry | one compact-and-retry | (not documented) |
| Retries | 408/425/429/5xx, backoff 1–16 s | (provider layer) | (not documented) |

## What awl should take (ranked by expected value for long tasks and for speed)

1. **grep with context and limits** (`-C`/`-A`/`-B`, case-insensitive, max results). In zigport, awl's extra turns were one-name greps followed by `sed -n` range reads; one grep with context answers both. Directly targets the turn gap with pi.
2. **bash: save the full output to a log file when it is cut, and cut less.** Keep the start and the end (Grok); return the log path so the model can grep or read the middle later instead of rerunning a slow build. A smaller cap (~20 KB) also cuts prompt tokens on every later turn.
3. **Background commands** for servers, watchers and long test runs: `bash` with `background: true` starts a detached process group writing to a log file and returns its id and log path; awl kills leftover jobs on exit. Required for "rock solid" on real projects; T3 never needed it.
4. **Compaction, pi's lessons:** a structured summary format, file lists that awl tracks itself (files read / changed), and the conversation serialized to text for the summary request (no tool-call confusion, no reliance on `tool_choice: none`).
5. **edit `replace_all`** for renames.
6. **read: number only every 10th line** (Grok). Fewer tokens per read; still anchors for locating lines.
7. **One prompt line:** "Say something is done or tested only when tool output shows it." (Grok's work policy, pstack's prove-it-works.)

Not taking:
- **Grok's 25-tool surface and 5 KB policy.** It is the opposite of bare-bones, and it costs ~58 KB per request.
- **Grok's side summary requests.** They add wall time.
- **pi's 8192 output cap.** It cost pi an impl-spec run.

## Harder tier (T4), to build offline

The tasks need long horizons: 40–100 steps, several files, and a reason to go back and fix earlier mistakes. Each gets hidden tests, and `verify_tasks.sh` must show it fails unsolved and passes solved.
- **A server task:** start the app in the background, hit it with curl, fix a bug, restart. This tests background commands.
- **A slow test suite with a flaky dependency.** This tests full-output logs and retries.
- **A multi-stage migration across about 30 files,** where the history overflows a small window on purpose (`ARENA_CTX` around 32K). This tests compaction.
- **A bug whose obvious first fix is wrong.** This tests the attack-the-premise and checklist discipline.
- **A feature that needs a design decision** documented in the repo's AGENTS.md (rules over defaults).
