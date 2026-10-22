#!/bin/bash
# Interactive awl on an OpenRouter model. awl speaks plain HTTP only, so this starts the
# arena proxy (HTTPS, key, cost log) on localhost for the session and stops it on exit.
#
#   awl-or [awl args...]      e.g. awl-or, awl-or -c, awl-or -p "explain src/http.zig"
# Env: AWL_OR_MODEL (default deepseek/deepseek-v4.1-flash), AWL_OR_PROVIDER (default coreweave,inference-net)
set -u
HERE=$(dirname "$(readlink -f "$0")")
REPO=$(dirname "$HERE")
KEY=$HOME/.local/state/awl-arena/openrouter.key
LOG=$HOME/.local/state/awl-arena/awl-or
MODEL=${AWL_OR_MODEL:-deepseek/deepseek-v4.1-flash}
PROVIDER=${AWL_OR_PROVIDER:-coreweave,inference-net}
[ -r "$KEY" ] || { echo "awl-or: no key at $KEY"; exit 2; }
mkdir -p "$LOG"
python3 "$REPO/arena/proxy.py" --upstream https://openrouter.ai/api --out "$LOG" --key-file "$KEY" \
  --model "$MODEL" --ctx 262144 --provider "$PROVIDER" >"$LOG/port" &
PROXY=$!
trap 'kill $PROXY 2>/dev/null' EXIT
for _ in $(seq 100); do [ -s "$LOG/port" ] && break; sleep 0.05; done
AWL_REASONING=${AWL_REASONING:-low} AWL_URL=http://127.0.0.1:$(cat "$LOG/port") AWL_KEY=openrouter AWL_MODEL=$MODEL "$REPO/zig-out/bin/awl" "$@"
rc=$?
cat "$LOG"/none.jsonl 2>/dev/null | python3 -c "
import sys, json
rs = [json.loads(l) for l in sys.stdin]
print(f'awl-or: \${sum(r.get(\"cost\", 0) or 0 for r in rs):.4f} spent through this proxy so far (all sessions)')" >&2
exit $rc
