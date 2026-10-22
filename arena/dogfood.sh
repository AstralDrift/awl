#!/bin/bash
# Dogfood: a harness works on the awl repo itself, through the arena proxy (OpenRouter by default).
# Real backlog work doubles as a head-to-head: by default awl and pi each get the same task,
# from the same commit, in separate clones.
#
#   arena/dogfood.sh NAME PROMPT_FILE [--h "awl pi"] [--base COMMIT] [--budget USD-per-harness]
#
# - Each harness works in a throwaway clone at /tmp/awl-dogfood/NAME-<harness> with no git remote,
#   so nothing can be pushed. Changes stay uncommitted there for review.
# - Every request is logged (tokens, cost) under arena/results/dogfood/NAME/<harness>/.
# - The prompt should say what to change and which checks to run (zig build test / e2e / check).
set -eu
NAME=$1
PROMPT_FILE=$(readlink -f "$2")
shift 2
HARNESSES="awl pi"
BASE=HEAD
BUDGET=0.25
while [ $# -gt 0 ]; do
  case $1 in
    --h) HARNESSES=$2 ;;
    --base) BASE=$2 ;;
    --budget) BUDGET=$2 ;;
    *) echo "dogfood: unknown option $1"; exit 2 ;;
  esac
  shift 2
done
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
KEY=$HOME/.local/state/awl-arena/openrouter.key
MODEL=${DOGFOOD_MODEL:-deepseek/deepseek-v4.1-flash}
PROVIDER=${DOGFOOD_PROVIDER:-coreweave,inference-net}
BASE_SHA=$(git -C "$REPO" rev-parse "$BASE")
# zig from the main repo's mise pin (a clone's mise.toml is untrusted at a new path)
Z=$(cd "$REPO" && mise where zig) && export PATH="$Z:$PATH"
(cd "$REPO" && zig build >/dev/null) # the awl doing the work = current main

run() { # harness
  local h=$1 wd=/tmp/awl-dogfood/$NAME-$1 out=$HERE/results/dogfood/$NAME/$1
  [ -e "$wd" ] && { echo "dogfood: $wd exists; pick a new NAME or remove it"; return 2; }
  mkdir -p /tmp/awl-dogfood "$out"
  git clone -q --no-hardlinks "$REPO" "$wd"
  git -C "$wd" checkout -q "$BASE_SHA"
  git -C "$wd" remote remove origin
  python3 "$HERE/proxy.py" --upstream https://openrouter.ai/api --out "$out/proxy" --key-file "$KEY" \
    --model "$MODEL" --ctx 262144 --provider "$PROVIDER" >"$out/port" &
  local proxy=$!
  for _ in $(seq 100); do [ -s "$out/port" ] && break; sleep 0.05; done
  local url=http://127.0.0.1:$(cat "$out/port")
  # Guard: stop the harness when it passes the budget, or stalls (no first request within 120 s,
  # or no new request for 300 s). Nothing may sit silently.
  (
    start=$(date +%s)
    while kill -0 $proxy 2>/dev/null; do
      spent=$(cat "$out"/proxy/*.jsonl 2>/dev/null | python3 -c "import sys,json; print(sum(json.loads(l).get('cost',0) or 0 for l in sys.stdin))")
      last=$(stat -c %Y "$out"/proxy/*.jsonl "$out"/proxy/*.active 2>/dev/null | sort -n | tail -1)
      now=$(date +%s)
      why=""
      python3 -c "import sys; sys.exit(0 if $spent >= $BUDGET else 1)" && why="hit the \$$BUDGET budget"
      [ -z "$last" ] && [ $((now - start)) -gt 120 ] && why="STALLED: no request in 120 s"
      [ -n "$last" ] && [ $((now - last)) -gt 300 ] && why="STALLED: no request for 300 s"
      if [ -n "$why" ]; then
        echo "dogfood: $h $why, stopping it" | tee -a "$out/summary.txt" >&2
        pkill -INT -f "^$REPO/zig-out/bin/awl -p|^pi --provider omarchy-local" || true
        sleep 5
        pkill -KILL -f "^$REPO/zig-out/bin/awl -p|^pi --provider omarchy-local" || true
        break
      fi
      sleep 5
    done
  ) &
  local guard=$! t0 rc
  t0=$(date +%s)
  set +e
  if [ "$h" = awl ]; then
    (cd "$wd" && XDG_STATE_HOME=$out/state AWL_URL=$url AWL_KEY=dogfood AWL_MODEL=$MODEL \
      timeout 1800 "$REPO/zig-out/bin/awl" -p "$(cat "$PROMPT_FILE")" >"$out/answer.md" 2>"$out/log.txt" </dev/null)
  else
    ARENA_CTX=262144 timeout 1800 "$HERE/adapters/$h.sh" "$wd" "$PROMPT_FILE" "$url" "$MODEL" >"$out/answer.md" 2>"$out/log.txt" </dev/null
  fi
  rc=$?
  set -e
  kill $proxy $guard 2>/dev/null || true
  wait $proxy 2>/dev/null || true
  cat "$out"/proxy/*.jsonl | python3 -c "
import sys, json
rs = [json.loads(l) for l in sys.stdin]
print(f'{\"$h\":4} exit $rc  {$(date +%s) - $t0:4d} s  {len(rs):3d} requests  '
      f'{sum(r[\"prompt_tokens\"] for r in rs):8d} prompt  {sum(r[\"completion_tokens\"] for r in rs):6d} completion  '
      f'\${sum(r.get(\"cost\", 0) or 0 for r in rs):.4f}')" | tee "$out/summary.txt"
  git -C "$wd" diff --stat | tail -1
}

echo "dogfood $NAME from $(git -C "$REPO" log --oneline -1 "$BASE_SHA") on $MODEL"
for h in $HARNESSES; do run "$h"; done
