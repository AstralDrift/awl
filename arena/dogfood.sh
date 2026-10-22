#!/bin/bash
# Dogfood: awl works on the awl repo itself, through the arena proxy (OpenRouter by default).
#
#   arena/dogfood.sh NAME PROMPT_FILE [--budget USD]
#
# - Works in a throwaway clone at /tmp/awl-dogfood/NAME with no git remote, so nothing can be pushed.
#   Changes stay uncommitted there for review; bring them over with
#   git -C /tmp/awl-dogfood/NAME diff | git apply
# - Every request is logged (tokens, cost) under arena/results/dogfood/NAME/.
# - The prompt should say what to change and which checks to run (zig build test / e2e / check).
set -eu
NAME=$1
PROMPT=$(cat "$2")
BUDGET=${4:-0.25}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WD=/tmp/awl-dogfood/$NAME
OUT=$HERE/results/dogfood/$NAME
KEY=$HOME/.local/state/awl-arena/openrouter.key
MODEL=${DOGFOOD_MODEL:-deepseek/deepseek-v4.1-flash}
PROVIDER=${DOGFOOD_PROVIDER:-coreweave,inference-net}

[ -e "$WD" ] && { echo "dogfood: $WD exists; pick a new NAME or remove it"; exit 2; }
mkdir -p /tmp/awl-dogfood "$OUT"
git clone -q --no-hardlinks "$REPO" "$WD"
git -C "$WD" remote remove origin
# zig from the main repo's mise pin (the clone's mise.toml is untrusted at a new path)
Z=$(cd "$REPO" && mise where zig) && export PATH="$Z:$PATH"
(cd "$REPO" && zig build -Doptimize=ReleaseSmall >/dev/null)  # the awl doing the work = current main

python3 "$HERE/proxy.py" --upstream https://openrouter.ai/api --out "$OUT/proxy" --key-file "$KEY" \
  --model "$MODEL" --ctx 262144 --provider "$PROVIDER" >"$OUT/port" &
PROXY=$!
trap 'kill $PROXY 2>/dev/null' EXIT
for _ in $(seq 100); do [ -s "$OUT/port" ] && break; sleep 0.05; done
PORT=$(cat "$OUT/port")

# Budget guard: stop awl if the logged cost passes the budget.
(
  while kill -0 $PROXY 2>/dev/null; do
    spent=$(cat "$OUT"/proxy/*.jsonl 2>/dev/null | python3 -c "import sys,json; print(sum(json.loads(l).get('cost',0) or 0 for l in sys.stdin))")
    if python3 -c "import sys; sys.exit(0 if $spent >= $BUDGET else 1)"; then
      echo "dogfood: budget \$$BUDGET reached, stopping awl" >&2
      pkill -INT -f "^$REPO/zig-out/bin/awl -p" || true
      break
    fi
    sleep 5
  done
) &

t0=$(date +%s)
cd "$WD"
set +e
XDG_STATE_HOME=$OUT/state AWL_URL=http://127.0.0.1:$PORT AWL_KEY=dogfood AWL_MODEL=$MODEL \
  timeout 1800 "$REPO/zig-out/bin/awl" -p "$PROMPT" 2>"$OUT/awl.log" | tee "$OUT/answer.md"
rc=${PIPESTATUS[0]}
set -e
cat "$OUT"/proxy/*.jsonl | python3 -c "
import sys, json
rs = [json.loads(l) for l in sys.stdin]
print(f'dogfood $NAME: exit $rc, {$(date +%s) - $t0} s, {len(rs)} requests, '
      f'{sum(r[\"prompt_tokens\"] for r in rs)} prompt / {sum(r[\"completion_tokens\"] for r in rs)} completion tokens, '
      f'\${sum(r.get(\"cost\", 0) or 0 for r in rs):.4f}')" | tee "$OUT/summary.txt"
git -C "$WD" status --short
git -C "$WD" diff --stat
