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
assert m[3]["content"] == "1→hello world\n", repr(m[3]["content"])
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
want = f"\nIn {sys.argv[2]}/skp/.agents/skills/<name>/SKILL.md:\n- demo: Demo skill for tests. Second line."
assert want in s, s[s.find("# Skills"):][:400]
assert "SECRET-BODY" not in s
EOF
stop

# 3. server error is reported, exit 1
echo '[{"status":500,"content":"model exploded"}]' >"$W/err.json"
serve "$W/err.json"
out=$(cd "$W" && AWL_RETRIES=1 "$AWL" -p hi 2>&1)
rc=$?
[ $rc -eq 1 ] && case "$out" in *"model exploded"*) true ;; *) false ;; esac && ok "http 500 reported" || bad "http 500" "rc=$rc $out"
stop

# 3b. transient errors are retried with backoff; a 4xx is not
echo '[{"status":503,"content":"overloaded"},{"status":429,"content":"slow down"},{"content":"recovered"}]' >"$W/retry.json"
serve "$W/retry.json"
t0=$(date +%s%N)
out=$(cd "$W" && "$AWL" -p hi 2>"$W/rerr")
ms=$((($(date +%s%N) - t0) / 1000000))
[ "$out" = "recovered" ] && grep -q "retry 1/5 in 1 s" "$W/rerr" && grep -q "retry 2/5 in 2 s" "$W/rerr" && [ $ms -ge 2900 ] && ok "503 + 429 retried (${ms} ms)" || bad "retry" "out=$out ms=$ms $(cat "$W/rerr")"
[ "$(wc -l <"$LOG")" -eq 3 ] && ok "retried requests sent" || bad "retried requests sent" "$(wc -l <"$LOG")"
stop
echo '[{"status":400,"content":"bad request"},{"content":"should not get here"}]' >"$W/r400.json"
serve "$W/r400.json"
out=$(cd "$W" && "$AWL" -p hi 2>&1)
rc=$?
[ $rc -eq 1 ] && [ "$(wc -l <"$LOG")" -eq 1 ] && ok "400 not retried" || bad "400 not retried" "rc=$rc $(wc -l <"$LOG") $out"
stop

# 3c. Ctrl-C during a retry wait stops at once
echo '[{"status":503,"content":"down"}]' >"$W/down.json"
serve "$W/down.json"
(cd "$W" && exec "$AWL" -p go >/dev/null 2>&1) &
apid=$!
sleep 0.5
t0=$(date +%s%N)
kill -INT $apid
wait $apid
rc=$?
ms=$((($(date +%s%N) - t0) / 1000000))
[ $rc -eq 130 ] && [ $ms -lt 200 ] && ok "ctrl-c in retry wait (${ms} ms)" || bad "ctrl-c in retry wait" "rc=$rc ${ms} ms"
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

# 6b. background jobs: started through the model, killed when awl exits
echo '[{"tool_calls":[{"name":"bash","arguments":{"command":"sleep 77","background":true}}]},{"content":"started"}]' >"$W/bg.json"
serve "$W/bg.json"
out=$(cd "$W" && "$AWL" -p go 2>/dev/null)
python3 - "$LOG" <<'EOF' && ok "background job started" || bad "background job" "$out"
import json, sys
m = [json.loads(l) for l in open(sys.argv[1])][-1]["messages"]
assert [x for x in m if x["role"] == "tool"][0]["content"].startswith("started background job ")
EOF
sleep 0.3
pgrep -f "^sleep 77" >/dev/null && bad "background job killed on exit" "still running" || ok "background job killed on exit"
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

# 8b. the checklist survives context elision; old reads around it are elided
python3 - "$W/ctodo.json" <<'EOF'
import json, sys
items = [{"text": f"step {i}: " + "x" * 40, "status": "doing" if i == 0 else "pending"} for i in range(10)]
t = [{"tool_calls": [{"name": "todo", "arguments": {"items": items}}], "usage": {"prompt_tokens": 400, "completion_tokens": 5}}]
t += [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}], "usage": {"prompt_tokens": 500 + 100 * i, "completion_tokens": 5}} for i in range(12)]
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/ctodo.json" --ctx 1500
(cd "$W" && "$AWL" -p go >/dev/null 2>"$W/o")
python3 - "$LOG" <<'EOF' && ok "checklist survives elision" || bad "checklist survives elision" "see above"
import json, sys
m = [json.loads(l) for l in open(sys.argv[1])][-1]["messages"]
tools = [x["content"] for x in m if x["role"] == "tool"]
assert tools[0].startswith("Checklist (current):\n[>] step 0"), tools[0][:80]
assert len(tools[0]) > 400
assert any(c.startswith("[old tool output elided") for c in tools[1:]), "nothing elided"
EOF
stop

# 8c. compaction: over 80% after elision -> summary request (no tools), history rebuilt
python3 - "$W/cmp.json" <<'EOF'
import json, sys
items = [{"text": "port the parser", "status": "doing"}, {"text": "run tests", "status": "pending"}]
t = [{"tool_calls": [{"name": "todo", "arguments": {"items": items}}], "usage": {"prompt_tokens": 500, "completion_tokens": 5}}]
t += [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}], "usage": {"prompt_tokens": p, "completion_tokens": 5}} for p in (1000, 1500, 2000, 2700)]
t.append({"content": "SUMMARY: goal is X; parser half ported in src/p.zig; next run zig build test.", "usage": {"prompt_tokens": 2700, "completion_tokens": 30}})
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/cmp.json" --ctx 3000
out=$(cd "$W" && "$AWL" -p "go port it" 2>"$W/o")
python3 - "$LOG" <<'EOF' && ok "compaction rebuilds history" || bad "compaction" "$out $(tail -3 "$W/o")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
ask, last = reqs[-2], reqs[-1]
assert ask.get("tool_choice") == "none", ask.get("tool_choice")
assert [x["role"] for x in ask["messages"]] == ["system", "user"], [x["role"] for x in ask["messages"]]
t = ask["messages"][-1]["content"]
assert "exceed the context window" in t and "## Goal" in t and "<conversation>" in t, t[:300]
assert "[User]: go port it" in t and "[Assistant tool calls]: read(" in t, t[-600:]
assert "earlier messages omitted" in t or "[Assistant tool calls]: todo(" in t, t[-600:]  # all of it, or the newest that fit
m = last["messages"]
assert m[1] == {"role": "user", "content": "go port it"}, m[1]
s = m[2]["content"]
assert s.startswith("[Earlier work, summarized") and "SUMMARY: goal is X" in s and "Checklist (current):\n[>] port the parser" in s, s
assert "<read-files>\nbig.txt\n</read-files>" in s, s
assert len(m) == 3 or m[3]["role"] == "assistant", [x["role"] for x in m]
assert len(m) < len(reqs[-3]["messages"]), (len(m), len(reqs[-3]["messages"]))
ids = {c["id"] for x in m if x["role"] == "assistant" for c in x.get("tool_calls") or []}
assert all(x["tool_call_id"] in ids for x in m if x["role"] == "tool"), "orphan tool result"
EOF
[ "$out" = "done" ] && grep -q "compacted:" "$W/o" && ok "compaction transparent to -p" || bad "compaction -p" "$out"
stop

# 8c2. compaction with a bigger window keeps recent messages, starting at an assistant turn
python3 - "$W/cmp2.json" <<'EOF'
import json, sys
# small outputs only, so elision cannot free room and compaction has to run
t = [{"tool_calls": [{"name": "bash", "arguments": {"command": f"echo step {i}"}}, {"name": "bash", "arguments": {"command": "echo hi"}}], "usage": {"prompt_tokens": p, "completion_tokens": 5}} for i, p in enumerate((2000, 3000, 4000, 5000, 6000, 7000, 7600))]
t.append({"content": "SUMMARY: ran seven steps of echo commands; next: finish.", "usage": {"prompt_tokens": 7600, "completion_tokens": 30}})
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/cmp2.json" --ctx 9000
out=$(cd "$W" && "$AWL" -p "loop" 2>"$W/o")
python3 - "$LOG" <<'EOF' && ok "compaction keeps a valid recent tail" || bad "compaction tail" "$out $(tail -3 "$W/o")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
m = reqs[-1]["messages"]
roles = [x["role"] for x in m]
assert roles[:3] == ["system", "user", "user"] and len(m) > 3 and roles[3] == "assistant", roles
ids = {c["id"] for x in m if x["role"] == "assistant" for c in x.get("tool_calls") or []}
assert ids and all(x["tool_call_id"] in ids for x in m if x["role"] == "tool"), "orphan tool result"
for i, x in enumerate(m):  # every assistant tool call is answered
    for c in x.get("tool_calls") or []:
        assert any(y.get("tool_call_id") == c["id"] for y in m[i + 1:]), c["id"]
EOF
stop

# 8c2. reasoning_effort: medium by default; a server that rejects it gets the request again without it
echo '[{"status": 400, "content": "Unexpected reasoning effort medium. Supported types are xhigh."}, {"content": "fine"}]' > "$W/re.json"
serve "$W/re.json"
out=$(cd "$W" && "$AWL" -p go 2>"$W/o")
python3 - "$LOG" "$out" <<'EOF2' && ok "reasoning_effort dropped after a 400 about it" || bad "reasoning fallback" "$out $(tail -2 "$W/o")"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "fine", sys.argv[2]
assert r[0]["reasoning_effort"] == "medium" and "reasoning_effort" not in r[1], [x.get("reasoning_effort") for x in r]
EOF2
stop

# 8c3. max_tokens sent by default; a reply cut off with no tool call gets a "continue" nudge
echo '[{"reasoning": "hmm hmm", "finish": "length"}, {"content": "finished"}]' > "$W/cut.json"
serve "$W/cut.json"
out=$(cd "$W" && "$AWL" -p go 2>"$W/o")
python3 - "$LOG" "$out" <<'EOF2' && ok "length cut -> continue; max_tokens 16384" || bad "length cut" "$out $(tail -2 "$W/o")"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "finished", sys.argv[2]
assert r[0]["max_tokens"] == 16384, r[0].get("max_tokens")
assert "output token limit" in r[1]["messages"][-1]["content"], r[1]["messages"][-1]
EOF2
stop
serve "$W/hi.json"
out=$(cd "$W" && AWL_MAX_TOKENS=0 "$AWL" -p go 2>/dev/null)
python3 -c "import json,sys; r=json.loads(open(sys.argv[1]).readline()); assert 'max_tokens' not in r" "$LOG" && ok "AWL_MAX_TOKENS=0 sends no cap" || bad "max_tokens off" "$out"
stop

# 8d. a "too long" rejection forces one compaction and the run continues (window unknown)
python3 - "$W/c400.json" <<'EOF'
import json, sys
t = [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}]} for _ in range(3)]
t.append({"status": 400, "content": "This model's maximum context length is 8192 tokens. Please reduce the length."})
t.append({"content": "SUMMARY: read big.txt three times; nothing else to do."})
t.append({"content": "recovered"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/c400.json"
out=$(cd "$W" && "$AWL" -p go 2>"$W/o")
[ "$out" = "recovered" ] && grep -q "compacted:" "$W/o" && ok "400 too-long -> compact -> continue" || bad "400 too-long" "$out $(tail -3 "$W/o")"
python3 - "$LOG" <<'EOF' && ok "forced summary request is smaller than the history" || bad "forced summary size" "see above"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
too_long, ask = reqs[3], reqs[4]
assert len(json.dumps(ask["messages"])) < len(json.dumps(too_long["messages"])), (len(json.dumps(ask["messages"])), len(json.dumps(too_long["messages"])))
EOF
stop

# 9. interactive TUI through a pty
python3 "$HERE/tui.py" "$AWL" >"$W/tui.out" 2>&1 && ok "tui ($(grep -c '^ok' "$W/tui.out") checks)" || bad "tui" "$(grep FAIL "$W/tui.out")"

echo "e2e: $pass passed, $fail failed"
[ $fail -eq 0 ]
