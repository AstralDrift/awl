# awl

[![CI](https://github.com/AstralDrift/awl/actions/workflows/ci.yml/badge.svg)](https://github.com/AstralDrift/awl/actions/workflows/ci.yml)

A coding agent for the terminal, built to beat the popular ones on results, speed and cost with
the smallest possible footprint. One static Zig binary (no libc, no runtime, ~340 KB) that talks
to any OpenAI-compatible server: Omarchy Local AI on your GPU, or OpenRouter in the cloud.

The model gets seven tools: read, write, edit (one change or an `edits` list, all or nothing),
bash (with background jobs), todo (a checklist that survives context trimming), grep (ripgrep)
and find (fd). Everything else is a lean loop that keeps the prompt small.

## Results

**Terminal-Bench 2.0**, 20-task subset (4 easy, 16 medium, 15-minute limits), every agent on the
same model, tasks and settings, run through [Harbor](https://github.com/harbor-framework/harbor):

<!-- results:tb -->
**Cloud: DeepSeek V4.1 Flash** (OpenRouter, Relace provider, medium reasoning, 10 tasks at a time):

| Agent | Solved | Median time per task | Cost of the 20 tasks | Requests |
|---|---|---|---|---|
| **awl** | **17 / 20** | **83 s** | $0.47 | 571 |
| pi | 15 / 20 | 104 s | **$0.16** | 273 |
| opencode | 15 / 20 | 93 s | $0.55 | 408 |

**Local: Qwen3.8-27B** (EXL3 on one RTX 4090, 2 tasks at a time):

| Agent | Solved | Tokens per task | Finished but wrong |
|---|---|---|---|
| **awl** | **12 / 20** | 182K | **2** |
| pi | 11 / 20 | 363K | 3 |
| mini-swe-agent | 10 / 20 | 273K | 5 |
| Terminus 2 (Terminal-Bench's reference agent) | 9 / 20 | 162K | 8 |
<!-- /results:tb -->

awl solved the most tasks on both models and was fastest per task in the cloud. It also works
longer per task: on DeepSeek it made twice pi's requests and cost about 3x as much (still under
$0.50 for all 20 tasks). Each table is one run of 20 tasks, so a gap of one or two tasks is within
noise. Method, per-task tables and every run are in [arena/LOG.md](arena/LOG.md); reproduce with
`arena/tb.sh` (see Benchmarks below).

**Footprint**, measured on the same machine:

| | awl | pi |
|---|---|---|
| Install | **234 KB**, one static file | 107 MB binary |
| Startup (`--version`) | **0.2 ms** | 205 ms |
| Memory of the harness process | **~0.3 MB** idle, < 1 MB peak over 50 turns | ~135-155 MB |
| Prompt per request (Terminal-Bench, local Qwen) | **8.9K tokens** | 17.5K tokens |

## Quick start

    mise install          # pins Zig 0.16.0
    zig build -Doptimize=ReleaseSmall
    ./zig-out/bin/awl     # TUI, on the Local AI model
    ./zig-out/bin/awl -p "fix the failing test"
    arena/awl-or.sh       # same, on an OpenRouter model (key in ~/.local/state/awl-arena/openrouter.key)

Spec and history: [PLAN.md](PLAN.md). Sibling project for macOS: `nib`.

## The TUI

Inline, so the terminal keeps its scrollback and plain copy and paste. Replies stream with light
markdown (headings, **bold**, `code`, bullets, task lists, quotes, rules, clickable links, code blocks
without fence lines, tables with aligned columns that wrap to fit); edits show the changed lines in
red and green; a read is one line (how much), a command shows its last lines, a search its first; a dim `⋯ 12s` line shows that a slow model call or command is still working.

While it works you can keep typing: Enter queues the message and the model gets it at its next
step (to steer it), or as the next prompt if it has finished. Esc or Ctrl-C stops the turn, and
anything you queued or typed comes back in the prompt. `/help` lists the keys.

Each turn ends with one line: model, time, steps, files changed, context use and awl's own
memory. A turn of 15 s or more that ends while the terminal is not focused rings the bell and
sends a desktop notification (`notify-send`).

A paste or dictation taller than the screen is shown as a window around the cursor; Ctrl-O
prints all of it so you can scroll up and read it, and sending prints it once. At an empty
prompt Ctrl-O (or `/expand`) prints the last tool output in full. `/copy` puts the last reply on
the clipboard, `/copy code` its last code block (through the terminal, OSC 52: kitty, foot,
ghostty, alacritty, and over ssh).

## Sessions and input

- Every conversation is saved under `~/.local/state/awl/sessions/`. `/resume` lists the ones
  started in this folder, `/resume N` opens one, `awl -c` continues the newest; `/new` starts over.
- On start, awl shows the model and its window, the mode, the folder and git branch, how many
  AGENTS.md files and skills it loaded, and the last conversation held in this folder.
- A status line under the prompt shows the model, context use (amber from 60%, when old tool
  output starts being trimmed; red from 80%, near summarizing), the mode and the git branch.
- When the model keeps a checklist (the todo tool), it stays pinned above the timer while the
  model and tools work: finished items fold into a count, the one in progress is highlighted. Ctrl-T hides it (a `☰ 2/5` count stays on the timer line) and shows it again.
- Full-screen mode (`awl --full`, `AWL_FULL=1`, or `/full` to switch either way): the
  conversation scrolls above a fixed input and status line (PgUp/PgDn or the mouse wheel; an
  arrow at the top right says how far up you are; Shift-drag selects text). Leaving it prints
  the conversation on the normal screen, so it stays in the scrollback.
- Colors follow the active Omarchy theme and change with it (from the next prompt).
- Prompt history is kept across sessions: ↑↓, and Ctrl-R finds older prompts containing what you typed.
- Pickers: a list you filter by typing and choose from with ↑↓ and Enter (Esc cancels).
  Tab after `@` picks from the project's files (fd) when the name is not unique; Tab after `/`
  picks a command; `/resume` and `/model` without an argument pick a conversation or a model
  from the server's list. Ctrl-P switches to the next model in `AWL_MODELS`, or opens the model picker.
- `@path` attaches a small text file to the message (Tab completes names); `!cmd` runs a shell
  command yourself and passes its output to the model with your next message.
- Ctrl-G writes the prompt in `$VISUAL` / `$EDITOR` (vi when neither is set). Esc Esc at an empty
  prompt (or `/rewind`) goes back to before an earlier prompt: pick it, then choose whether the
  files changed since go back too (tracked like `/undo`). The prompt returns to the input line, and
  the conversation as it was stays in ← as "… (before rewind)".
- Prompt commands: `~/.config/awl/prompts/NAME.md` or `<project>/.agents/prompts/NAME.md` runs as
  `/NAME args` (`$ARGUMENTS`, `$1`..`$9`; an optional `description:` front matter shows in the
  picker and `/help`). `/review` (the uncommitted changes, read only) and `/init` (an AGENTS.md)
  are built in; a file with the same name replaces them.
- `/diff` shows every uncommitted change, new files included, colored.
- The terminal title shows the folder, with `⋯` while awl works and `?` while it waits for you;
  the old title comes back on exit (`AWL_TITLE=off` leaves it alone).
- `/model NAME` switches model, `/compact` summarizes the conversation now, `/context` shows the
  window use and the files read and changed. A `/command` typed while the model works runs when
  the turn ends.

## Agents and sessions (←)

Press ← at an empty prompt (or `/agents`) for a full-screen view of this folder's conversations
and background agents. It updates live, groups what needs you first (**Needs you**, **Running**,
**Sessions**), and previews the selected one: its state, any question it is waiting on, and the
end of its conversation. Wide terminals show the preview beside the list, narrow ones below it.

- **Background agents** run on their own while you keep working: `n` in the view, or `/bg TASK`
  at the prompt. Each is a separate `awl --bg` process with its own sandbox, using the current
  model and mode. It keeps running if you close awl, and sends a desktop notification when it
  finishes or needs you.
- `m` messages the selected one: a running agent reads it before its next step (steering); a
  finished or saved session continues in the background with it.
- `y` / `d` answer an agent's question (a command in ask mode, the network, a guarded file).
- `x` stops an agent; `⏎` opens a session here (or zooms a running agent's live transcript);
  `space` zooms the preview; `r` renames; `f` forks a copy and opens it; `⌫` deletes (asks
  first); `/` searches; `⇥` switches between this folder and all folders; `esc` or `←` goes back.
- The status line shows `◆ 2 agents running` or `? 1 needs you`, and a note above the prompt
  says when an agent finished or is waiting.
- A session is open in one place at a time: one in use by a background agent or another
  terminal cannot be resumed (`-r`, `-c`, `/resume`, the view) until that one is done.
- How it works: every running awl keeps a small `<session>.live` status file and holds a lock
  on it, so a crashed agent never shows as running. A background agent reads messages from
  `<session>.inbox` and answers from `<session>.answer`; its own output goes to `<session>.log`.

## Safety

- **Sandbox** (bubblewrap, required by default): the model's commands (bash, background jobs, grep, find)
  run in one sandbox per session. They see the filesystem read-only and can write only to the project
  (git root or cwd), `/tmp`, build caches and `AWL_SANDBOX_WRITE` dirs. Hidden from them: `~/.ssh`,
  `~/.gnupg`, cloud/gh credentials, keyrings, the Local AI key, `/run/user` (D-Bus, Hyprland, keyring
  sockets), sockets under `/tmp`, the docker socket, other processes, and any environment variable not on
  a short allowlist (names with TOKEN, KEY, SECRET, PASS, AUTH, ... never pass). They cannot create user
  namespaces. The project's `.git/config`, `.git/hooks`, `AGENTS.md` and `.agents/` are read-only to them,
  since git runs hooks and fsmonitor outside the sandbox and the next session reads those instructions.
- **No network unless you say yes.** Commands share a private localhost (a dev server started in the
  background is reachable from the next command) but nothing beyond it. When the model needs the
  internet it sets `network: true` on one bash call; awl shows the command and asks `allow? y/n` in every
  mode, for that call only. With no terminal (`awl -p`) the answer is no. `AWL_SANDBOX_NET=on` gives
  every command the network without asking.
- write/edit follow the same write rule after resolving symlinks, and ask before every change to `.git`,
  `AGENTS.md` or `.agents/`; read refuses the hidden paths. Without `/usr/bin/bwrap` the model's commands
  are refused (install bubblewrap); `AWL_SANDBOX=off` turns all of it off. Your own `!cmd` is never
  sandboxed.
- `/undo` puts back the files the last turn wrote or edited (and removes files it created);
  repeat it to go further back. The model is told what was undone. Changes made by shell
  commands are not tracked.
- `/mode auto` (default) runs everything; `/mode ask` shows each edit's diff and each command
  and waits for y/n (p = always allow this command's prefix, e.g. `zig build`, for the session;
  a command that chains, substitutes or redirects still asks; a = allow the rest: switches to auto); `/mode plan` keeps files read-only and asks before
  commands, so the model investigates and proposes. `AWL_MODE` sets the starting mode.

## What it loads

- `AGENTS.md`: your own `~/.config/awl/AGENTS.md` (or `$XDG_CONFIG_HOME/awl/`), then the git root
  down to the working directory, outermost first so the nearest wins (24 KB cap). Nothing above the
  repository; outside one, only the working directory's file. `AWL_AGENTS=off` loads none.
- Skills in the Agent Skills format from `~/.agents/skills/` and `<project>/.agents/skills/`:
  only each skill's name and description go in the prompt; the model reads a `SKILL.md` when a task
  matches. This repo's `skills/` holds three single-agent playbooks (bug fix, feature, refactor)
  and a few principles adapted from pstack (MIT).

## Long sessions

- Old tool outputs are trimmed when the prompt passes 60% of the window; the checklist is never trimmed.
- If that is not enough (80%), or the server says the request is too long, the model summarizes the
  work and awl continues from the task, the summary, the checklist and the newest messages.
- Transient model errors (connection loss, 408/425/429/5xx) are retried with backoff; Ctrl-C stops a wait.
- Commands the model runs never see `AWL_*` variables (so not the API key).

## Settings (environment only)

| Variable | Default | Meaning |
|---|---|---|
| `AWL_URL` | `http://127.0.0.1:12434` | OpenAI-compatible server (plain HTTP) |
| `AWL_MODEL` | first model the server lists | model id |
| `AWL_KEY` | Local AI gateway key | bearer token |
| `AWL_MAX_STEPS` | 200 | model calls per prompt |
| `AWL_RETRIES` | 5 | retries for transient model errors |
| `AWL_REASONING` | `medium` | `reasoning_effort` to send (`low`, `medium`, `xhigh`, ...; `off` sends none). Local AI's Qwen defaults to xhigh, about twice the tokens per turn; dropped automatically if a server rejects it |
| `AWL_MAX_TOKENS` | `65536` | output cap per reply (`max_tokens`; `0` sends none). Generous so heavy thinkers are not cut off. A reply cut off before any tool call gets a note asking the model to continue; one cut off inside a tool call runs nothing and asks for the call again |
| `AWL_SYSTEM` | built in | file with a replacement system prompt |
| `AWL_AGENTS` | on | `off` loads no AGENTS.md files (clean evals and benchmarks) |
| `AWL_MODE` | `auto` | `auto`, `ask` (approve commands and edits) or `plan` (read-only) |
| `AWL_STATUS` | `model,ctx,mode,branch,agents` | items of the status line under the prompt, in order: `model`, `ctx`, `mode`, `branch`, `dir`, `session`, `agents` (background agents running or waiting); `off` hides it |
| `AWL_WELCOME` | on | `off` shrinks the startup screen to one line |
| `AWL_MODELS` | unset | comma-separated models that Ctrl-P cycles through |
| `AWL_THINK_BUDGET` | unset | `N`: send `custom_params: {thinking_budget: N}` (SGLang started with `--enable-strict-thinking` ends reasoning after N tokens) |
| `AWL_THINKING` | on | `off`: every request sends `chat_template_kwargs: {enable_thinking: false}` (Nanbeige4.3, Qwen3.x templates); faster, less deliberate |
| `AWL_KEEP_REASONING` | on | send each turn's reasoning back as `reasoning_content`; chat templates (Nanbeige4.3, Qwen3.x) re-render it, so the history matches what the model generated and the server's prefix cache keeps hitting. `0`: off |
| `AWL_THINK_ROWS` | `6` | rows of the model's newest reasoning shown live (word-wrapped, above the timer); they fold into one `∴ thought Ns` line when it answers. `0`: timer only |
| `AWL_DEBUG_KEYS` | unset | file to append every raw input chunk to, escaped (`\e` = Esc): shows exactly what the terminal sends on a keypress or paste |
| `AWL_TITLE` | on | `off`: leave the terminal's title alone |
| `AWL_FULL` | unset | `1` starts in full-screen mode (same as `--full`) |

## Benchmarks

### Terminal-Bench 2.0 (Harbor)

    harbor dataset download terminal-bench@2.0 -o arena/results/tb/tb2   # once
    export TB_UPSTREAM=openrouter TB_PROVIDER=relace TB_N=10 TB_BUDGET=2  # cloud: fast, no GPU
    arena/tb.sh awl $(arena/tb.sh --subset)       # the 20-task subset
    arena/tb.sh awl -i fix-git                    # one task
    python3 arena/tb_report.py                    # per-task table, tokens, time

Agents: `awl`, `pi`, `opencode`, `terminus-2`, `mini-swe-agent`, `hermes`. `arena/harbor/awl_agent.py`
holds awl's Harbor adapter (it uploads the static binary into each task container) and fixes for
Harbor's mini-swe-agent and Hermes installs. Every agent reaches the model through one proxy
container (`arena/proxy.py`) that adds the key, logs tokens and cost per agent, sets the same
`reasoning_effort` for all (`TB_REASONING`, default `medium`), pins one provider (`TB_PROVIDER`)
and refuses requests past `TB_BUDGET` dollars. Without `TB_UPSTREAM` it uses the Local AI model.
`TB_MODEL` picks the model (default `deepseek/deepseek-v4.1-flash-1017`), `TB_TASKS` the task set
(for example Terminal-Bench 2.1). Task containers get no AGENTS.md, so every agent starts equal.

### Arena (head-to-head against pi, omp, grok on our own tasks)

    python3 arena/run.py t0                                   # awl only, no model: budgets + e2e
    python3 arena/run.py t3                                   # 10 coding tasks x 2, awl vs pi, Local AI
    python3 arena/run.py t3 --upstream openrouter --budget 1  # same on OpenRouter (DeepSeek V4.1 Flash)
    python3 arena/run.py t3 --h all                           # awl, pi, omp, grok
    python3 arena/status.py                                   # progress of a running arena
    python3 arena/report.py [results.jsonl] [--accept]
    arena/dogfood.sh NAME PROMPT_FILE                         # awl and pi each do real work on this repo
    arena/qa.sh NAME                                          # QA: awl works on a throwaway clone of itself

Every harness goes through `arena/proxy.py`, which records turns, tokens, cached tokens, cost and
model time per run, and stops a harness that stalls. Tasks live in `arena/tasks/<id>/`
(`prompt.txt`, `setup/`, `check.sh`, hidden tests, `solve.sh`); `arena/verify_tasks.sh` proves each
check fails unsolved and passes solved. Every experiment gets a line in `arena/LOG.md`.

### Self-improvement (`arena/evolve.py`, after Harness2's propose / probe / compose)

    python3 arena/evolve.py init NAME                          # start from the built-in system prompt
    python3 arena/evolve.py step NAME --steps 3 --upstream URL # propose, probe, confirm, adopt or reject
    python3 arena/evolve.py heldout NAME --upstream URL        # held-out tier t5: best prompt vs the start
    python3 arena/evolve.py show NAME

The model under test reads its own failed or slow runs on six tune tasks and proposes one general edit
to the system prompt (naming a task or task file gets the proposal rejected). The candidate runs the tune
tasks; if it looks better, both prompts run again and it is adopted only if it still wins with both runs
pooled (passes first, then >= 5% less wall time). Adopted and rejected edits go to `lessons.md` with their
numbers; the proposer sees them next time. Tier t5 is never shown to the proposer. State: `arena/evolve/NAME/`.

## License

MIT (see [LICENSE](LICENSE)). The skills adapted from pstack keep pstack's MIT notice next to them.
Releases: push a tag like `v0.2.0` and the Release workflow attaches the static `awl-x86_64-linux`
binary and its SHA-256 to a GitHub release.
