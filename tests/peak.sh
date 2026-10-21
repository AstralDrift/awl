#!/bin/bash
# Peak RSS (KB) of awl over a scripted 50-turn session with tool calls. Prints one number.
set -eu
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
seq 1 400 | sed 's/^/line of text number /' >"$W/data.txt"
python3 - "$W/s.json" <<'PY'
import json, sys
turns = []
for i in range(49):
    call = [{"name": "read", "arguments": {"path": "data.txt"}},
            {"name": "bash", "arguments": {"command": "seq 1 300"}},
            {"name": "grep", "arguments": {"pattern": "number 1"}}][i % 3]
    turns.append({"reasoning": "thinking " * 40, "content": "step %d " % i + "x" * 400, "tool_calls": [call]})
turns.append({"content": "finished"})
json.dump(turns, open(sys.argv[1], "w"))
PY
python3 "$HERE/fake_sse.py" "$W/s.json" --split 0 >"$W/port" &
for _ in $(seq 50); do [ -s "$W/port" ] && break; sleep 0.02; done
cd "$W"
AWL_RSS=1 XDG_STATE_HOME=$W/state AWL_URL=http://127.0.0.1:$(cat "$W/port") AWL_MAX_STEPS=60 \
  "$AWL" -p "go" 2>"$W/err" >/dev/null
grep -o 'peak_rss_kb [0-9]*' "$W/err" | awk '{print $2}'
