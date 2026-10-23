# awl

A bare-metal coding-agent harness and inline TUI for Omarchy Linux. Written in Zig, static, no libc,
~160 KB, under 1 MB of memory for a 50-turn session.
It talks to the Omarchy Local AI gateway (`127.0.0.1:12434`) and gives the model seven tools:
read, write, edit (one change or an `edits` list, all or nothing), bash, todo (a checklist that
survives context trimming), grep (ripgrep) and find (fd).

Spec and build order: [PLAN.md](PLAN.md). Sibling project for macOS: `nib`.

    mise install          # pins Zig 0.16.0
    zig build -Doptimize=ReleaseSmall
    ./zig-out/bin/awl     # TUI
    ./zig-out/bin/awl -p "fix the failing test"
    arena/awl-or.sh       # same, on an OpenRouter model (key in ~/.local/state/awl-arena/openrouter.key)

## The TUI

Inline, so the terminal keeps its scrollback and plain copy and paste. Replies stream with light
markdown (headings, **bold**, `code`, bullets, fenced blocks); edits show the changed lines in
red and green; a dim `⋯ 12s` line shows that a slow model call or command is still working.

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
  model and tools work: finished items fold into a count, the one in progress is highlighted.
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
- `/model NAME` switches model, `/compact` summarizes the conversation now, `/context` shows the
  window use and the files read and changed. A `/command` typed while the model works runs when
  the turn ends.

## Safety

- `/undo` puts back the files the last turn wrote or edited (and removes files it created);
  repeat it to go further back. The model is told what was undone. Changes made by shell
  commands are not tracked.
- `/mode auto` (default) runs everything; `/mode ask` shows each edit's diff and each command
  and waits for y/n (a = allow the rest: switches to auto); `/mode plan` keeps files read-only and asks before
  commands, so the model investigates and proposes. `AWL_MODE` sets the starting mode.

## What it loads

- `AGENTS.md` from the working directory and every parent up to `/`, outermost first (24 KB cap).
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
| `AWL_MAX_TOKENS` | `16384` | output cap per reply (`max_tokens`, as pi sends; `0` sends none). A reply cut off before any tool call gets a note asking the model to continue |
| `AWL_SYSTEM` | built in | file with a replacement system prompt |
| `AWL_MODE` | `auto` | `auto`, `ask` (approve commands and edits) or `plan` (read-only) |
| `AWL_STATUS` | `model,ctx,mode,branch` | items of the status line under the prompt, in order: `model`, `ctx`, `mode`, `branch`, `dir`, `session`; `off` hides it |
| `AWL_WELCOME` | on | `off` shrinks the startup screen to one line |
| `AWL_MODELS` | unset | comma-separated models that Ctrl-P cycles through |
| `AWL_FULL` | unset | `1` starts in full-screen mode (same as `--full`) |

## Arena (benchmark against pi, omp, grok)

    python3 arena/run.py t0                                   # awl only, no model: budgets + e2e
    python3 arena/run.py t3                                   # 10 coding tasks x 2, awl vs pi, Local AI
    python3 arena/run.py t3 --upstream openrouter --budget 1  # same on OpenRouter (DeepSeek V4.1 Flash)
    python3 arena/run.py t3 --h all                           # awl, pi, omp, grok
    python3 arena/status.py                                   # progress of a running arena
    python3 arena/report.py [results.jsonl] [--accept]
    arena/dogfood.sh NAME PROMPT_FILE                         # awl and pi each do real work on this repo

Every harness goes through `arena/proxy.py`, which records turns, tokens, cached tokens, cost and
model time per run, and stops a harness that stalls. Tasks live in `arena/tasks/<id>/`
(`prompt.txt`, `setup/`, `check.sh`, hidden tests, `solve.sh`); `arena/verify_tasks.sh` proves each
check fails unsolved and passes solved. Every experiment gets a line in `arena/LOG.md`.
