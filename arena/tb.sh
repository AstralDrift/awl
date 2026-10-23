#!/bin/bash
# Terminal-Bench 2.0 through Harbor, on the Local AI model.
#
#   arena/tb.sh AGENT [harbor run args...]    AGENT: awl | terminus-2 | mini-swe-agent | pi
#   e.g. arena/tb.sh awl -i fix-git           one task
#        arena/tb.sh awl $(arena/tb.sh --subset)
#
# - Tasks: arena/results/tb/tb2/terminal-bench (harbor dataset download terminal-bench@2.0).
# - Every agent talks to the model through one proxy container (awl-tbproxy) on the
#   gateway's Docker network: it adds the gateway key (agents only see "local"), logs
#   tokens per agent to results/tb/proxy/AGENT.jsonl, and sets reasoning_effort=medium
#   on every request so all agents run the model the same way.
# - Task containers join that network through a compose overlay (ufw blocks container ->
#   host); terminus-2 runs on the host and uses the proxy's 127.0.0.1 port.
# - TB_N: concurrent trials (default 2; one GPU).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
SUBSET="overfull-hbox cobol-modernization fix-git prove-plus-comm log-summary-date-ranges
multi-source-data-merger regex-log query-optimize build-cython-ext sqlite-db-truncate db-wal-recovery
extract-elf gcode-to-text largest-eigenval crack-7z-hash openssl-selfsigned-cert sanitize-git-repo
git-multibranch nginx-request-logging polyglot-c-py"
if [ "${1:-}" = --subset ]; then for t in $SUBSET; do printf -- '-i %s ' "$t"; done; echo; exit 0; fi
AGENT=$1
shift
TB=$HERE/results/tb
PORT=18080
GW=$(docker ps --format '{{.Names}}' | grep -- '-gateway$' | head -1)
[ -n "$GW" ] || { echo "tb: no Local AI gateway container is running"; exit 2; }
NET=$(docker inspect "$GW" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
KEYF=$HOME/.local/state/omarchy/local-ai/gateway.key
read -r MODEL CTX < <(curl -s -m5 -H "Authorization: Bearer $(cat "$KEYF")" http://127.0.0.1:12434/v1/models |
  python3 -c 'import sys,json; m=json.load(sys.stdin)["data"][0]; print(m["id"], m.get("max_model_len", 0))')
mkdir -p "$TB/proxy" "$TB/jobs"
if ! docker ps --format '{{.Names}}' | grep -qx awl-tbproxy; then
  docker run -d --rm --name awl-tbproxy --network "$NET" -p 127.0.0.1:$PORT:$PORT --user "$(id -u):$(id -g)" \
    -v "$HERE/proxy.py:/proxy.py:ro" -v "$KEYF:/key:ro" -v "$TB/proxy:/out" python:3.13-alpine \
    python3 -u /proxy.py --upstream "http://$GW:12434" --out /out --port $PORT --host 0.0.0.0 \
    --key-file /key --model "$MODEL" --ctx "$CTX" --reasoning medium >/dev/null
  sleep 2
fi
PIP=$(docker inspect awl-tbproxy --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")
sed "s/@NET@/$NET/" "$HERE/harbor/gateway-net.yaml.in" >"$TB/gateway-net.yaml"
CBASE=http://$PIP:$PORT/run/$AGENT # as seen from task containers
HBASE=http://127.0.0.1:$PORT/run/$AGENT # as seen from the host
export OPENAI_API_KEY=local
ARGS=(-p "$TB/tb2/terminal-bench" -o "$TB/jobs" --job-name "$AGENT-$(date +%m%d-%H%M%S)" -n "${TB_N:-2}" -y
  --extra-docker-compose "$TB/gateway-net.yaml")
Z=$(cd "$REPO" && mise where zig) && export PATH="$Z:$PATH"
case $AGENT in
awl)
  BIN=$TB/awl-$(git -C "$REPO" rev-parse --short HEAD) # frozen copy for this job
  (cd "$REPO" && zig build -Doptimize=ReleaseSmall) && cp "$REPO/zig-out/bin/awl" "$BIN"
  export AWL_BIN=$BIN AWL_TB_URL=$CBASE AWL_TB_MODEL=$MODEL PYTHONPATH=$REPO
  ARGS+=(-a arena.harbor.awl_agent:Awl) ;;
terminus-2)
  ARGS+=(-a terminus-2 -m "openai/$MODEL" --ak "api_base=$HBASE/v1"
    --ak "model_info={\"max_input_tokens\": $CTX, \"max_output_tokens\": 32768, \"input_cost_per_token\": 0, \"output_cost_per_token\": 0}") ;;
mini-swe-agent)
  export OPENAI_API_BASE=$CBASE/v1 OPENAI_BASE_URL=$CBASE/v1
  export PYTHONPATH=$REPO
  ARGS+=(-a arena.harbor.awl_agent:MiniSweAgentFixed -m "openai/$MODEL") ;;
pi)
  export OPENAI_BASE_URL=$CBASE/v1
  ARGS+=(-a pi -m "openai/$MODEL" --ak model_api=openai-completions) ;;
*) echo "tb: unknown agent $AGENT"; exit 2 ;;
esac
exec harbor run "${ARGS[@]}" "$@" </dev/null
