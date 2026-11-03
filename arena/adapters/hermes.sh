#!/bin/bash
# Nous Research Hermes Agent, headless: one-shot, quiet, commands auto-approved, custom OpenAI-compatible endpoint.
# A fresh HERMES_HOME per run, so no memory or learned skills carry over between tasks (the other harnesses keep none).
# A fresh home runs Hermes's first-run setup, which stops without a TTY, so the model config is written first.
. "$(dirname "$0")/common.sh"
home=$(mktemp -d "$STATE/hermes-XXXXXX")
export HERMES_HOME=$home
hermes config set model.provider custom >/dev/null
hermes config set model.base_url "$BASE/v1" >/dev/null
hermes config set model.default "$MODEL" >/dev/null
hermes config set model.api_key "$KEY" >/dev/null
exec hermes chat --oneshot -Q --yolo --max-turns 200 \
  --provider custom --base-url "$BASE/v1" --api-key "$KEY" --model "$MODEL" -q "$PROMPT"
