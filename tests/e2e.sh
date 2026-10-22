#!/bin/bash
# End-to-end checks against tests/fake_sse.py (no GPU). Usage: tests/e2e.sh [path/to/awl]
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
export XDG_STATE_HOME=$W/state
# The caller's awl settings must not leak in (e.g. running inside an awl session).
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS
pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# serve SCRIPT [args...] -> sets PORT, LOG
serve() {
  local script=$1
  shift
  LOG=$W/req-$RANDOM.jsonl
  python3 "$HERE/fake_sse.py" "$script" --log "$LOG" "$@" >"$W/port" &
  for _ in $(seq 50); do [ -s "$W/port" ] && break; sleep 0.02; done
  PORT=$(cat "$W/port")
  : >"$W/port"
  export AWL_URL=http://127.0.0.1:$PORT
}
stop() { kill %% 2>/dev/null; wait 2>/dev/null; }

# 1. streaming in every transfer mode and split size
echo '[{"content":"héllo ✓ there"}]' >"$W/hi.json"
for m in "chunked 0" "chunked 1" "chunked 7" "length 3" "close 2"; do
  set -- $m
  serve "$W/hi.json" --mode "$1" --split "$2"
  out=$(cd "$W" && "$AWL" -p hi 2>&1)
  [ "$out" = "héllo ✓ there" ] && ok "stream $m" || bad "stream $m" "$out"
  stop
done

serve "$W/hi.json" --comments 1 --split 3
out=$(cd "$W" && "$AWL" -p hi 2>&1)
[ "$out" = "héllo ✓ there" ] && ok "stream with SSE comment lines" || bad "stream with SSE comment lines" "$out"
stop

# 2. tool loop: read -> edit + grep -> done
mkdir -p "$W/proj"
echo "hello world" >"$W/proj/hello.txt"
cat >"$W/loop.json" <<'EOF'
[{"reasoning":"look first","content":"Reading.","tool_calls":[{"name":"read","arguments":{"path":"hello.txt"}}]},
 {"tool_calls":[{"name":"edit","arguments":{"path":"hello.txt","old_string":"world","new_string":"awl"}},{"name":"grep","arguments":{"pattern":"awl"}}]},
 {"content":"Done."}]
EOF
serve "$W/loop.json" --split 5
out=$(cd "$W/proj" && "$AWL" -p "fix hello" 2>"$W/err")
rc=$?
[ $rc -eq 0 ] && ok "loop exit 0" || bad "loop exit" "rc=$rc $(cat "$W/err")"
[ "$(cat "$W/proj/hello.txt")" = "hello awl" ] && ok "edit applied" || bad "edit applied" "$(cat "$W/proj/hello.txt")"
case "$out" in *Done.) ok "final reply" ;; *) bad "final reply" "$out" ;; esac
python3 - "$LOG" <<'EOF' && ok "request history" || bad "request history" "see above"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert len(reqs) == 3, len(reqs)
m = reqs[-1]["messages"]
roles = [x["role"] for x in m]
assert roles == ["system", "user", "assistant", "tool", "assistant", "tool", "tool"], roles
assert m[3]["content"] == "     1\thello world\n", repr(m[3]["content"])
assert m[2]["tool_calls"][0]["function"]["name"] == "read"
assert json.loads(m[4]["tool_calls"][0]["function"]["arguments"])["new_string"] == "awl"
assert m[5]["tool_call_id"] == "call_0" and m[6]["tool_call_id"] == "call_1"
assert m[6]["content"].startswith("./hello.txt:1:hello awl") or m[6]["content"].startswith("hello.txt:1:"), m[6]["content"]
assert reqs[0]["stream"] is True
names = [t["function"]["name"] for t in reqs[0]["tools"]]
assert names[:4] == ["read", "write", "edit", "bash"], names
EOF
stop

# 2b. child processes get awl's env minus AWL_*: a bash `env` must not leak the key
cat >"$W/env.json" <<'EOF'
[{"tool_calls":[{"name":"bash","arguments":{"command":"env"}}]},
 {"content":"done"}]
EOF
serve "$W/env.json"
(cd "$W" && AWL_KEY=secret123 "$AWL" -p go >/dev/null 2>"$W/err")
python3 - "$LOG" <<'EOF' && ok "AWL_* not passed to child" || bad "AWL_* not passed to child" "secret123 leaked into tool output"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert len(reqs) == 2, len(reqs)
tool = reqs[-1]["messages"][-1]
assert tool["role"] == "tool", tool["role"]
assert "secret123" not in tool["content"], tool["content"]
assert "PATH=" in tool["content"], tool["content"]
EOF
stop

# 2c. AGENTS.md from every parent directory, outermost first (nearest wins conflicts)
mkdir -p "$W/outer/inner"
echo "OUTER-RULE" >"$W/outer/AGENTS.md"
echo "INNER-RULE" >"$W/outer/inner/AGENTS.md"
echo '[{"content":"ok"}]' >"$W/ag.json"
serve "$W/ag.json"
(cd "$W/outer/inner" && "$AWL" -p hi >/dev/null 2>&1)
python3 - "$LOG" "$W" <<'EOF' && ok "AGENTS.md from parents, outer first" || bad "AGENTS.md from parents" "see above"
import json, sys
sysmsg = json.loads(open(sys.argv[1]).readline())["messages"][0]["content"]
o, i = sysmsg.find("OUTER-RULE"), sysmsg.find("INNER-RULE")
assert 0 < o < i, (o, i, sysmsg[-300:])
assert f"# AGENTS.md from {sys.argv[2]}/outer\n" in sysmsg, sysmsg[-300:]
EOF
stop

# 2d. project skills: name + description listed, body left for the model to read
mkdir -p "$W/skp/.git" "$W/skp/sub" "$W/skp/.agents/skills/demo"
printf -- '---\nname: demo\ndescription: >\n  Demo skill for tests.\n  Second line.\n---\nSECRET-BODY\n' >"$W/skp/.agents/skills/demo/SKILL.md"
echo '[{"content":"ok"}]' >"$W/sk.json"
serve "$W/sk.json"
(cd "$W/skp/sub" && "$AWL" -p hi >/dev/null 2>&1)
python3 - "$LOG" "$W" <<'EOF' && ok "project skills listed" || bad "project skills listed" "see above"
import json, sys
s = json.loads(open(sys.argv[1]).readline())["messages"][0]["content"]
want = f"- demo: Demo skill for tests. Second line. ({sys.argv[2]}/skp/.agents/skills/demo/SKILL.md)"
assert want in s, s[s.find("# Skills"):][:400]
assert "SECRET-BODY" not in s
EOF
stop

# 3. server error is reported, exit 1
echo '[{"status":500,"content":"model exploded"}]' >"$W/err.json"
serve "$W/err.json"
out=$(cd "$W" && "$AWL" -p hi 2>&1)
rc=$?
[ $rc -eq 1 ] && case "$out" in *"model exploded"*) true ;; *) false ;; esac && ok "http 500 reported" || bad "http 500" "rc=$rc $out"
stop

# 4. no server: clear message, exit 2
AWL_URL=http://127.0.0.1:1 "$AWL" -p hi >"$W/o" 2>&1
rc=$?
[ $rc -eq 2 ] && grep -q "no model" "$W/o" && ok "no server" || bad "no server" "rc=$rc $(cat "$W/o")"

# 5. max steps
echo '[{"tool_calls":[{"name":"bash","arguments":{"command":"true"}}]}]' >"$W/inf.json"
serve "$W/inf.json"
AWL_MAX_STEPS=3 "$AWL" -p go >/dev/null 2>"$W/o"
rc=$?
[ $rc -eq 1 ] && grep -q "stopped after 3 steps" "$W/o" && ok "max steps" || bad "max steps" "rc=$rc $(cat "$W/o")"
stop

# 6. Ctrl-C during a long tool returns fast and kills the process group
echo '[{"tool_calls":[{"name":"bash","arguments":{"command":"sleep 100"}}]},{"content":"after"}]' >"$W/sleep.json"
serve "$W/sleep.json"
(cd "$W" && exec "$AWL" -p go >/dev/null 2>&1) &
apid=$!
sleep 0.5
t0=$(date +%s%N)
kill -INT $apid
wait $apid
rc=$?
ms=$((($(date +%s%N) - t0) / 1000000))
[ $rc -eq 130 ] && [ $ms -lt 100 ] && ok "ctrl-c in tool (${ms} ms)" || bad "ctrl-c in tool" "rc=$rc ${ms} ms"
pgrep -f "sleep 100" >/dev/null && bad "ctrl-c kills group" "sleep still running" || ok "ctrl-c kills group"
stop

# 7. session written and resumable
f=$(ls "$XDG_STATE_HOME"/awl/sessions/*.jsonl | head -1)
[ -n "$f" ] && head -1 "$f" | grep -q '"awl"' && ok "session file" || bad "session file" "$f"
echo '[{"content":"resumed ok"}]' >"$W/res.json"
serve "$W/res.json"
out=$(cd "$W" && "$AWL" -c -p again 2>&1)
python3 -c "
import json,sys
m=json.loads(open('$LOG').readline())['messages']
assert len(m) > 3 and m[-1]['content']=='again', [x['role'] for x in m]" && [ "$out" = "resumed ok" ] && ok "resume -c" || bad "resume -c" "$out"
stop

# 8. old tool outputs are elided as the context fills; the newest stay
seq 1 300 >"$W/big.txt"
python3 "$HERE/ctx_script.py" "$W/ctx.json"
serve "$W/ctx.json" --ctx 1500
(cd "$W" && "$AWL" -p go >/dev/null 2>"$W/o")
python3 "$HERE/ctx_check.py" "$LOG" 2>"$W/o2" && ok "context elision" || bad "context elision" "$(tail -1 "$W/o2") $(cat "$W/o")"
stop

# 9. interactive TUI through a pty
python3 "$HERE/tui.py" "$AWL" >"$W/tui.out" 2>&1 && ok "tui ($(grep -c '^ok' "$W/tui.out") checks)" || bad "tui" "$(grep FAIL "$W/tui.out")"

echo "e2e: $pass passed, $fail failed"
[ $fail -eq 0 ]
