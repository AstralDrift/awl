# Adapters

`<harness>.sh WORKDIR PROMPT_FILE BASE_URL MODEL` runs one harness headless in WORKDIR,
pointed at BASE_URL (the arena proxy, no `/v1`), and exits when it is done.
Each one `exec`s the harness so the runner can measure its process tree.

| Harness | Invocation | Notes |
|---|---|---|
| awl | `awl -p` | `AWL_URL`, `AWL_MODEL`, `AWL_KEY`. Thinking is the server default. |
| pi | `pi --print --no-session --thinking medium` | `PI_CODING_AGENT_DIR` with a generated models.json |
| omp | `omp --print --auto-approve --approval-mode=yolo --no-session --thinking medium` | same models.json as pi |
| grok | `grok -p --always-approve --disable-web-search --max-turns 200` | `GROK_HOME` with a generated config.toml. Turn cap matches awl's 200 (was 40, which failed zigport). |

Invocations are taken from `~/Work/local-ai-harness-bench/run-round4*.sh`.
Versions are recorded per run by `run.py` into the results file.

## Fairness rules

- Workdirs live in `/tmp/awl-arena/<ts>/`, outside the repo and home, so no harness reads an unrelated
  `AGENTS.md` (before 2026-10-21 awl read the awl repo's own dev rules on every run).
- With a hosted upstream the proxy strips `reasoning_effort` / `reasoning` / `include_reasoning`, so every
  harness gets the model's default reasoning, and retries 429/502/503 itself, so rate limits never
  count against one harness.

## Hosted model (OpenRouter)

    echo 'sk-or-...' > ~/.local/state/awl-arena/openrouter.key && chmod 600 ~/.local/state/awl-arena/openrouter.key
    arena/run.py t3 --upstream openrouter [--model deepseek/deepseek-v4.1-flash] [--provider NAME] [--budget 1.50]

The proxy records OpenRouter's per-request cost; the runner stops starting runs once `--budget` USD is
spent. Baselines are kept per model (`baseline-<tier>-<model>.json`). `arena/test_proxy.py` tests all of
this offline.
