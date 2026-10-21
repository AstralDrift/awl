# Adapters

`<harness>.sh WORKDIR PROMPT_FILE BASE_URL MODEL` runs one harness headless in WORKDIR,
pointed at BASE_URL (the arena proxy, no `/v1`), and exits when it is done.
Each one `exec`s the harness so the runner can measure its process tree.

| Harness | Invocation | Notes |
|---|---|---|
| awl | `awl -p` | `AWL_URL`, `AWL_MODEL`, `AWL_KEY`. Thinking is the server default. |
| pi | `pi --print --no-session --thinking medium` | `PI_CODING_AGENT_DIR` with a generated models.json |
| omp | `omp --print --auto-approve --approval-mode=yolo --no-session --thinking medium` | same models.json as pi |
| grok | `grok -p --always-approve --disable-web-search --max-turns 40` | `GROK_HOME` with a generated config.toml |

Invocations are taken from `~/Work/local-ai-harness-bench/run-round4*.sh`.
Versions are recorded per run by `run.py` into the results file.
