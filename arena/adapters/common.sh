# Sourced by adapters. Args: WORKDIR PROMPT_FILE BASE_URL MODEL
# BASE_URL has no /v1 suffix. Config files holding the gateway key live under
# ~/.local/state/awl-arena, never in the repo.
WD=$1
PROMPT=$(cat "$2")
BASE=$3
MODEL=$4
KEY=$(cat "$HOME/.local/state/omarchy/local-ai/gateway.key")
CTX=${ARENA_CTX:-262144}
STATE=$HOME/.local/state/awl-arena
mkdir -p "$STATE"
cd "$WD"

pi_models() { # write a pi/omp models.json into $1
  mkdir -p "$1"
  jq -nc --arg u "$BASE/v1" --arg m "$MODEL" --arg k "$KEY" --argjson ctx "$CTX" '
    {providers: {"omarchy-local": {baseUrl: $u, apiKey: $k, api: "openai-completions",
      models: [{id: $m, name: $m, reasoning: true, contextWindow: $ctx, maxTokens: 8192,
        input: ["text"],
        thinkingLevelMap: {minimal: "low", low: "low", medium: "medium", high: "medium", xhigh: "medium", max: null},
        cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
        compat: {supportsDeveloperRole: false}}]}}}' >"$1/models.json"
}
