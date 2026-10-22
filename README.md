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
| `AWL_REASONING` | unset | `reasoning_effort` to send (hosted models; local Qwen ignores it) |
| `AWL_SYSTEM` | built in | file with a replacement system prompt |

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
