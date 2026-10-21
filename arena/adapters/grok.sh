#!/bin/bash
. "$(dirname "$0")/common.sh"
ag=$STATE/grok
mkdir -p "$ag"
{
  printf '[models]\ndefault = "omarchy-local"\n[features]\nremote_fetch = false\ntelemetry = false\n'
  printf '[model.omarchy-local]\nmodel = %s\nbase_url = %s\ncontext_window = %s\nenv_key = "XAI_API_KEY"\n' \
    "$(jq -n --arg v "$MODEL" '$v')" "$(jq -n --arg v "$BASE/v1" '$v')" "$CTX"
} >"$ag/config.toml"
XAI_API_KEY=$KEY GROK_HOME=$ag exec grok --model omarchy-local --always-approve --disable-web-search --max-turns 40 \
  --cwd "$WD" -p "$PROMPT"
