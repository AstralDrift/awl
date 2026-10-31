#!/bin/bash
# End-to-end checks against tests/fake_sse.py (no GPU). Usage: tests/e2e.sh [path/to/awl]
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
export XDG_STATE_HOME=$W/state
# The caller's awl settings must not leak in (e.g. running inside an awl session).
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS AWL_AGENTS AWL_CTX_MODE
export XDG_CONFIG_HOME=/nonexistent
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
import json, re, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert len(reqs) == 3, len(reqs)
m = reqs[-1]["messages"]
roles = [x["role"] for x in m]
assert roles == ["system", "user", "assistant", "tool", "assistant", "tool", "tool"], roles
assert m[3]["content"] == "1→hello world\n", repr(m[3]["content"])  # compact (default): no budget line
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

# 2c. AGENTS.md: the user's file, then the git root down to the cwd (outermost first,
# nearest wins conflicts); nothing above the repository; outside one, the cwd only
mkdir -p "$W/above/outer/.git" "$W/above/outer/inner" "$W/cfg/awl" "$W/loose/sub"
echo "ABOVE-RULE" >"$W/above/AGENTS.md"
echo "OUTER-RULE" >"$W/above/outer/AGENTS.md"
echo "INNER-RULE" >"$W/above/outer/inner/AGENTS.md"
echo "GLOBAL-RULE" >"$W/cfg/awl/AGENTS.md"
echo "LOOSE-PARENT" >"$W/loose/AGENTS.md"
echo "LOOSE-HERE" >"$W/loose/sub/AGENTS.md"
sysmsg() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["messages"][0]["content"])' "$LOG"; }
echo '[{"content":"ok"}]' >"$W/ag.json"
serve "$W/ag.json"
(cd "$W/above/outer/inner" && XDG_CONFIG_HOME=$W/cfg "$AWL" -p hi >/dev/null 2>&1)
python3 - "$(sysmsg)" "$W" <<'EOF2' && ok "AGENTS.md: user file, then git root to cwd, nothing above the repo" || bad "AGENTS.md in a repo" "see above"
import sys
m = sys.argv[1]
g, o, i = m.find("GLOBAL-RULE"), m.find("OUTER-RULE"), m.find("INNER-RULE")
assert 0 < g < o < i, (g, o, i, m[-400:])
assert "ABOVE-RULE" not in m, m[-400:]
assert f"# AGENTS.md from {sys.argv[2]}/above/outer\n" in m, m[-400:]
EOF2
stop
serve "$W/ag.json"
(cd "$W/loose/sub" && XDG_CONFIG_HOME=$W/none "$AWL" -p hi >/dev/null 2>&1)
python3 - "$(sysmsg)" <<'EOF2' && ok "AGENTS.md outside a repo: the cwd only" || bad "AGENTS.md outside a repo" "see above"
import sys
m = sys.argv[1]
assert "LOOSE-HERE" in m and "LOOSE-PARENT" not in m, m[-300:]
EOF2
stop
serve "$W/ag.json"
(cd "$W/above/outer/inner" && XDG_CONFIG_HOME=$W/cfg AWL_AGENTS=off "$AWL" -p hi >/dev/null 2>&1)
python3 - "$(sysmsg)" <<'EOF2' && ok "AWL_AGENTS=off loads none" || bad "AWL_AGENTS=off" "see above"
import sys
assert "-RULE" not in sys.argv[1], sys.argv[1][-300:]
EOF2
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
python3 "$HERE/ctx_check.py" "$LOG" compact 2>"$W/o2" && ok "context elision (compact: old marker, no view)" || bad "context elision (compact)" "$(tail -1 "$W/o2") $(cat "$W/o")"
stop
serve "$W/ctx.json" --ctx 1500
(cd "$W" && AWL_CTX_MODE=fresh "$AWL" -p go >/dev/null 2>"$W/o")
python3 "$HERE/ctx_check.py" "$LOG" fresh 2>"$W/o2" && ok "context elision (fresh: marker points into the view)" || bad "context elision (fresh)" "$(tail -1 "$W/o2") $(cat "$W/o")"
stop

# 8b. the checklist survives context elision; old reads around it are elided
python3 - "$W/ctodo.json" <<'EOF'
import json, sys
items = [{"text": f"step {i}: " + "x" * 40, "status": "doing" if i == 0 else "pending"} for i in range(10)]
t = [{"tool_calls": [{"name": "todo", "arguments": {"items": items}}], "usage": {"prompt_tokens": 400, "completion_tokens": 5}}]
# under 80% of the window throughout: elision alone, no reset
t += [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}], "usage": {"prompt_tokens": min(500 + 100 * i, 1150), "completion_tokens": 5}} for i in range(12)]
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

# 8c. compaction (AWL_CTX_MODE=compact, the default): over 80% after elision -> summary request (no tools), history rebuilt
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
python3 - "$LOG" "$out" <<'EOF2' && ok "length cut -> continue; max_tokens 65536" || bad "length cut" "$out $(tail -2 "$W/o")"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "finished", sys.argv[2]
assert r[0]["max_tokens"] == 65536, r[0].get("max_tokens")
assert "output token limit" in r[1]["messages"][-1]["content"], r[1]["messages"][-1]
assert r[1].get("chat_template_kwargs") == {"enable_thinking": False} and "chat_template_kwargs" not in r[0], [x.get("chat_template_kwargs") for x in r]
assert all("reasoning_content" not in m for m in r[1]["messages"] if m["role"] == "assistant"), "cut-off reasoning was sent back"
EOF2
stop
# AWL_THINK_MAX: a reply still thinking past the cap is stopped; its plan goes back, the next request acts without thinking
python3 -c "import json; print(json.dumps([{'reasoning': 'plan step ' * 40, 'content': 'never shown'}, {'content': 'acted'}]))" > "$W/tmax.json"
serve "$W/tmax.json"
out=$(cd "$W" && AWL_THINK_MAX=10 "$AWL" -p go 2>"$W/o")
python3 - "$LOG" "$out" <<'EOF2' && ok "AWL_THINK_MAX stops long thinking, keeps the plan, next reply without thinking" || bad "think max" "$out $(tail -2 "$W/o")"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "acted", sys.argv[2]
assert len(r) == 2, len(r)
assert "budget" in r[1]["messages"][-1]["content"], r[1]["messages"][-1]
assert r[1].get("chat_template_kwargs") == {"enable_thinking": False} and "chat_template_kwargs" not in r[0]
a = [m for m in r[1]["messages"] if m["role"] == "assistant"][-1]
assert a.get("reasoning_content", "").startswith("plan step") and 40 < len(a["reasoning_content"]) < 100, a
EOF2
stop
# max_tokens fits the window: sized per request, and shrunk to what a server says is left
echo '[{"content": "fits"}]' > "$W/fit.json"
serve "$W/fit.json" --ctx 8000
out=$(cd "$W" && "$AWL" -p go 2>/dev/null)
python3 -c "import json,sys; r=json.loads(open(sys.argv[1]).readline()); assert 1024 <= r['max_tokens'] <= 8000 - 256, r['max_tokens']" "$LOG" && [ "$out" = fits ] && ok "max_tokens sized to the known window" || bad "max_tokens fit" "$out"
stop
echo '[{"status": 400, "content": "Requested token count exceeds the model'"'"'s maximum context length of 49152 tokens. You requested a total of 50186 tokens: 1034 tokens from the input messages and 49152 tokens for the completion."}, {"content": "shrunk ok"}]' > "$W/shrink.json"
serve "$W/shrink.json"
out=$(cd "$W" && "$AWL" -p go 2>"$W/o")
python3 -c "import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; assert len(r) == 2 and r[1]['max_tokens'] == 49152 - 1034 - 64, [x.get('max_tokens') for x in r]" "$LOG" && [ "$out" = "shrunk ok" ] && ! grep -q compacted "$W/o" && ok "400 'exceeds context' -> max_tokens shrunk, no compaction" || bad "shrink" "$out $(tail -2 "$W/o")"
stop
# AWL_THINK_BUDGET sends SGLang's per-request thinking cap
serve "$W/hi.json"
out=$(cd "$W" && AWL_THINK_BUDGET=1024 "$AWL" -p go 2>/dev/null)
python3 -c "import json,sys; r=json.loads(open(sys.argv[1]).readline()); assert r.get('custom_params') == {'thinking_budget': 1024}, r.get('custom_params')" "$LOG" && ok "AWL_THINK_BUDGET sends custom_params" || bad "think budget" "$out"
stop
# AWL_THINKING=off asks every request for no thinking
serve "$W/hi.json"
out=$(cd "$W" && AWL_THINKING=off "$AWL" -p go 2>/dev/null)
python3 -c "import json,sys; r=json.loads(open(sys.argv[1]).readline()); assert r.get('chat_template_kwargs') == {'enable_thinking': False}, r.get('chat_template_kwargs')" "$LOG" && ok "AWL_THINKING=off sends enable_thinking false" || bad "thinking off" "$out"
stop
# a call cut off mid-arguments goes back to the server as {} (templates iterate arguments as a mapping)
echo '[{"tool_calls": [{"name": "write", "arguments": "{\"path\": \"cut2.txt\""}], "finish": "length"}, {"content": "finished"}]' > "$W/cutargs.json"
serve "$W/cutargs.json"
out=$(cd "$W" && "$AWL" -p go 2>/dev/null)
python3 - "$LOG" "$out" "$W/cut2.txt" <<'EOF2' && ok "cut-off arguments sent back as {}" || bad "cut args" "$out"
import json, os, sys
r = [json.loads(l) for l in open(sys.argv[1])]
a = [m for m in r[1]["messages"] if m["role"] == "assistant"][-1]
assert sys.argv[2] == "finished", sys.argv[2]
assert a["tool_calls"][0]["function"]["arguments"] == "{}", a
assert not os.path.exists(sys.argv[3])
EOF2
stop
# the reasoning goes back with its turn (chat templates re-render it; prefix caches stay valid)
echo '[{"reasoning": "  look at the file first\n", "tool_calls": [{"name": "bash", "arguments": {"command": "true"}}]}, {"content": "kept"}]' > "$W/keep.json"
serve "$W/keep.json"
out=$(cd "$W" && "$AWL" -p go 2>/dev/null)
python3 - "$LOG" "$out" <<'EOF2' && ok "reasoning_content sent back with its turn" || bad "keep reasoning" "$out"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
a = [m for m in r[1]["messages"] if m["role"] == "assistant"][-1]
assert sys.argv[2] == "kept", sys.argv[2]
assert a.get("reasoning_content") == "look at the file first", a
EOF2
stop
serve "$W/keep.json"
out=$(cd "$W" && AWL_KEEP_REASONING=0 "$AWL" -p go 2>/dev/null)
python3 -c "import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; a=[m for m in r[1]['messages'] if m['role']=='assistant'][-1]; assert 'reasoning_content' not in a, a" "$LOG" && ok "AWL_KEEP_REASONING=0 sends none" || bad "keep reasoning off" "$out"
stop
# grep and find given an absolute path inside the project print short relative paths (long absolute ones get mis-copied)
mkdir -p "$W/relsub" && echo "needle_rel" > "$W/relsub/r.txt"
python3 -c "import json,sys; print(json.dumps([{'tool_calls': [{'name': 'grep', 'arguments': {'pattern': 'needle_rel', 'path': sys.argv[1] + '/relsub'}}, {'name': 'find', 'arguments': {'pattern': 'r.txt', 'path': sys.argv[1]}}]}, {'content': 'rel ok'}]))" "$W" > "$W/rel.json"
serve "$W/rel.json"
out=$(cd "$W" && "$AWL" -p go 2>/dev/null)
python3 - "$LOG" "$W" <<'EOF2' && ok "grep/find inside the project print relative paths" || bad "relative paths" "$out"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
res = [m["content"] for m in r[1]["messages"] if m["role"] == "tool"]
assert "relsub/r.txt:1:needle_rel" in res[0] and sys.argv[2] not in res[0], res[0]
assert "relsub/r.txt" in res[1] and sys.argv[2] not in res[1], res[1]
EOF2
stop
# loop detector: the same call with the same output is flagged from the 3rd time; a changing output never is
echo "needle_rep" > "$W/rep.txt"
python3 -c "
import json
g={'name':'grep','arguments':{'pattern':'needle_rep','path':'rep.txt'}}
b={'name':'bash','arguments':{'command':'date +%N'}}
print(json.dumps([{'tool_calls':[g,b]}]*4+[{'content':'rep ok'}]))" > "$W/rep.json"
serve "$W/rep.json"
out=$(cd "$W" && "$AWL" -p go 2>/dev/null)
python3 - "$LOG" "$out" <<'EOF2' && ok "same call + same result flagged from the 3rd time; changing output never" || bad "repeat detector" "$out"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "rep ok", sys.argv[2]
res = [m["content"] for m in r[-1]["messages"] if m["role"] == "tool"]
greps, dates = res[0::2], res[1::2]
flag = "exact call"
assert [flag in x for x in greps] == [False, False, True, True], greps
assert not any(flag in x for x in dates), dates
EOF2
stop
# a runaway reply (a stuck model once wrote 171 near-identical calls): the stream stops at call 17, 16 run, the model is told
python3 -c "import json; print(json.dumps([{'tool_calls': [{'name': 'bash', 'arguments': {'command': 'echo run%d >> runaway.txt' % i}} for i in range(20)]}, {'content': 'calmer'}]))" > "$W/runaway.json"
serve "$W/runaway.json"
rm -f "$W/runaway.txt"
out=$(cd "$W" && "$AWL" -p go 2>"$W/o")
python3 - "$LOG" "$out" "$W/runaway.txt" <<'EOF2' && ok "runaway reply: 16 calls run, the rest stopped, model told" || bad "runaway" "$out $(tail -2 "$W/o")"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "calmer", sys.argv[2]
assert open(sys.argv[3]).read().split() == ["run%d" % i for i in range(16)]
m = r[1]["messages"]
a = [x for x in m if x["role"] == "assistant"][-1]
assert len(a["tool_calls"]) == 16, len(a["tool_calls"])
res = [x for x in m if x["role"] == "tool"]
assert len(res) == 16 and "at most 16 tool calls" in res[-1]["content"] and "at most" not in res[0]["content"], res[-1]
EOF2
stop
# a reply cut off inside a tool call: nothing runs, the model is asked to redo the call
echo '[{"tool_calls": [{"name": "write", "arguments": {"path": "cutfile.txt", "content": "half"}}], "finish": "length"}, {"content": "finished"}]' > "$W/cutcall.json"
serve "$W/cutcall.json"
out=$(cd "$W" && "$AWL" -p go 2>"$W/o")
python3 - "$LOG" "$out" "$W/cutfile.txt" <<'EOF2' && ok "length cut inside a tool call -> not run, redo asked" || bad "length cut in call" "$out $(tail -2 "$W/o")"
import json, os, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "finished", sys.argv[2]
assert not os.path.exists(sys.argv[3]), "the cut call ran"
assert "[not run:" in r[1]["messages"][-1]["content"], r[1]["messages"][-1]
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

# 8e. retrieval (AWL_CTX_MODE=fresh): over 80% after elision -> no model request; the history becomes the
# first user message + one note naming the session view + checklist + files, then the newest messages
python3 - "$W/rr.json" <<'EOF'
import json, sys
items = [{"text": "port the parser", "status": "doing"}, {"text": "run tests", "status": "pending"}]
t = [{"tool_calls": [{"name": "todo", "arguments": {"items": items}}], "usage": {"prompt_tokens": 500, "completion_tokens": 5}}]
t += [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}], "usage": {"prompt_tokens": p, "completion_tokens": 5}} for p in (1000, 1500, 2000, 2700)]
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/rr.json" --ctx 3000
out=$(cd "$W" && AWL_CTX_MODE=fresh "$AWL" -p "go port it" 2>"$W/o")
python3 - "$LOG" <<'EOF' && ok "retrieval reset: no summary request, note names the view" || bad "retrieval reset" "$out $(tail -3 "$W/o")"
import json, re, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert len(reqs) == 6, len(reqs)  # one per script turn: nothing extra
assert all("tool_choice" not in r for r in reqs), [r.get("tool_choice") for r in reqs]
m = reqs[-1]["messages"]
assert m[1] == {"role": "user", "content": "go port it"}, m[1]
s = m[2]["content"]
assert s.startswith("[Context reset:"), s[:100]
assert re.search(r"/view-\d+\.txt", s), s
assert "grep" in s and "summar" not in s.split("]")[0].replace("not summarized", ""), s
assert "Checklist (current):\n[>] port the parser" in s, s
assert "<read-files>\nbig.txt\n</read-files>" in s, s
assert len(m) == 3 or m[3]["role"] == "assistant", [x["role"] for x in m]
assert len(m) < len(reqs[-2]["messages"]), (len(m), len(reqs[-2]["messages"]))
ids = {c["id"] for x in m if x["role"] == "assistant" for c in x.get("tool_calls") or []}
assert all(x["tool_call_id"] in ids for x in m if x["role"] == "tool"), "orphan tool result"
EOF
[ "$out" = "done" ] && grep -q "context reset:" "$W/o" && ok "retrieval reset transparent to -p" || bad "retrieval -p" "$out $(cat "$W/o")"
stop

# 8e2. retrieval with a bigger window keeps a valid recent tail (every result keeps its call)
python3 - "$W/rr2.json" <<'EOF'
import json, sys
t = [{"tool_calls": [{"name": "bash", "arguments": {"command": f"echo step {i}"}}, {"name": "bash", "arguments": {"command": "echo hi"}}], "usage": {"prompt_tokens": p, "completion_tokens": 5}} for i, p in enumerate((2000, 3000, 4000, 5000, 6000, 7000, 7600))]
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/rr2.json" --ctx 9000
out=$(cd "$W" && AWL_CTX_MODE=fresh "$AWL" -p "loop" 2>"$W/o")
python3 - "$LOG" <<'EOF' && ok "retrieval keeps a valid recent tail" || bad "retrieval tail" "$out $(tail -3 "$W/o")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert len(reqs) == 8, len(reqs)
m = reqs[-1]["messages"]
roles = [x["role"] for x in m]
assert roles[:3] == ["system", "user", "user"] and len(m) > 3 and roles[3] == "assistant", roles
assert m[2]["content"].startswith("[Context reset:"), m[2]["content"][:80]
ids = {c["id"] for x in m if x["role"] == "assistant" for c in x.get("tool_calls") or []}
assert ids and all(x["tool_call_id"] in ids for x in m if x["role"] == "tool"), "orphan tool result"
for i, x in enumerate(m):
    for c in x.get("tool_calls") or []:
        assert any(y.get("tool_call_id") == c["id"] for y in m[i + 1:]), c["id"]
EOF
stop

# 8e3. a "too long" rejection resets the context (no summary request) and the run continues
python3 - "$W/r400.json" <<'EOF'
import json, sys
t = [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}]} for _ in range(3)]
t.append({"status": 400, "content": "This model's maximum context length is 8192 tokens. Please reduce the length."})
t.append({"content": "recovered"})
json.dump(t, open(sys.argv[1], "w"))
EOF
serve "$W/r400.json"
out=$(cd "$W" && AWL_CTX_MODE=fresh "$AWL" -p go 2>"$W/o")
python3 - "$LOG" "$out" <<'EOF' && ok "400 too-long -> reset -> continue" || bad "400 reset" "$out $(tail -3 "$W/o")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "recovered", sys.argv[2]
assert len(reqs) == 5, len(reqs)
too_long, after = reqs[3], reqs[4]
assert after["messages"][2]["content"].startswith("[Context reset:"), after["messages"][2]["content"][:80]
assert len(json.dumps(after["messages"])) < len(json.dumps(too_long["messages"]))
EOF
stop

# 8e4. a resumed session already over the window resets before its first request, and the newest
# prompt survives even when it alone is bigger than the tail that is kept
python3 - "$W/rlong.json" <<'EOF'
import json, sys
t = [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}]} for _ in range(8)]
t.append({"content": "first done"})
json.dump(t, open(sys.argv[1], "w"))
EOF
mkdir -p "$W/rs"
cp "$W/big.txt" "$W/rs/"
serve "$W/rlong.json" --ctx 100000
(cd "$W/rs" && AWL_CTX_MODE=fresh "$AWL" -p "first task" >/dev/null 2>&1)
stop
echo '[{"content":"second ok"}]' >"$W/rsec.json"
serve "$W/rsec.json" --ctx 3000
big_prompt="second task: $(printf 'y%.0s' $(seq 4000))"
out=$(cd "$W/rs" && AWL_CTX_MODE=fresh "$AWL" -c -p "$big_prompt" 2>"$W/o")
python3 - "$LOG" "$out" <<'EOF' && ok "resume over the window resets at step 0; newest prompt kept" || bad "resume reset" "$out $(tail -3 "$W/o")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "second ok", sys.argv[2]
assert len(reqs) == 1, len(reqs)
m = reqs[0]["messages"]
assert m[1] == {"role": "user", "content": "first task"}, m[1]
assert m[-1]["role"] == "user", [x["role"] for x in m]
s = m[2]["content"]
assert s.startswith("[Context reset:") and "second task: yyyy" in s, s[:200]
assert len(json.dumps(m)) < 12000, len(json.dumps(m))
EOF
stop

# 8e5. a torn last line (a crash mid-write) is skipped on resume, and the next record starts on a line of its own
S=$W/torn.jsonl
printf '%s\n%s\n%s\n%s' '{"awl":"0","model":"fake-model","cwd":"/x"}' '{"role":"user","content":"before"}' '{"role":"assistant","content":"first answer"}' '{"role":"user","content":"tor' >"$S"
echo '[{"content":"after torn"}]' >"$W/torn.json"
serve "$W/torn.json"
out=$(cd "$W" && AWL_CTX_MODE=fresh "$AWL" -r "$S" -p next 2>"$W/o")
python3 - "$LOG" "$out" "$S" <<'EOF' && ok "torn last line skipped; next record on its own line" || bad "torn line" "$out $(tail -3 "$W/o")"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "after torn", sys.argv[2]
m = reqs[0]["messages"]
assert [x["role"] for x in m] == ["system", "user", "assistant", "user"], [x["role"] for x in m]
assert m[-1]["content"] == "next", m[-1]
lines = open(sys.argv[3]).read().split("\n")
assert lines[3] == '{"role":"user","content":"tor', lines[3]
for l in lines[4:]:
    if l:
        json.loads(l)
assert json.loads(lines[4])["content"] == "next" and json.loads(lines[5])["content"] == "after torn", lines[4:]
EOF
stop

# 8e6. an 11 MB session: resumed, reset at once, and its middle found with grep in the view (from the
# sandboxed bash: the view is the one session file the model's commands can see)
python3 - "$W/huge.jsonl" <<'EOF'
import json, sys
f = open(sys.argv[1], "w")
d = lambda o: json.dumps(o, separators=(",", ":"))  # compact, as awl writes it
f.write(d({"awl": "0", "model": "fake-model", "cwd": "/x"}) + "\n")
f.write(d({"role": "user", "content": "build it"}) + "\n")
for i in range(170):
    f.write(d({"role": "assistant", "content": "", "tool_calls": [{"id": f"c{i}", "type": "function", "function": {"name": "bash", "arguments": d({"command": f"make part{i}"})}}]}) + "\n")
    body = "".join(f"part{i} line {k}: compiling module {k} of part {i}\n" for k in range(1300))
    if i == 85:
        body += 'NEEDLE-ERROR: disk quota 4242 exceeded in "/srv/build/out.bin"\n'
    f.write(d({"role": "tool", "tool_call_id": f"c{i}", "content": body}) + "\n")
EOF
cat >"$W/huge-s.json" <<'EOF'
[{"tool_calls":[{"name":"bash","arguments":{"command":"grep -n NEEDLE-ERROR $VIEW; grep -c '^{\"n\":' $VIEW; ls $(dirname $VIEW)"}}]},
 {"content":"found"}]
EOF
serve "$W/huge-s.json" --ctx 180000
t0=$(date +%s%N)
out=$(cd "$W" && AWL_CTX_MODE=fresh "$AWL" -r "$W/huge.jsonl" -p "find the error" 2>"$W/o")
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
python3 - "$LOG" "$out" "$W/huge.jsonl" <<'EOF' && ok "11 MB session: reset at once, needle found in the view (${ms} ms)" || bad "11 MB session" "$out $(tail -3 "$W/o")"
import json, os, sys
assert os.path.getsize(sys.argv[3]) > 10 << 20
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert sys.argv[2] == "found", sys.argv[2]
assert len(json.dumps(reqs[0]["messages"])) < 4 * 180000, len(json.dumps(reqs[0]["messages"]))
r = [x for x in reqs[1]["messages"] if x["role"] == "tool"][-1]["content"]
assert 'NEEDLE-ERROR: disk quota 4242 exceeded in "/srv/build/out.bin"' in r, r[:300]
lines = r.split("\n")
# the hit is in the loaded part (part 85 of 170), before this search's own call line (the view records it too)
hits = [l for l in lines if "NEEDLE-ERROR" in l]
assert hits[0].endswith('exceeded in "/srv/build/out.bin"') and "→ bash" in hits[-1], hits
counts = [l for l in lines if l.isdigit()]
assert counts == [str(1 + 2 * 170 + 2)], counts  # loaded messages + the new prompt + this reply
listing = [l for l in lines if l.startswith("view-") or l.endswith(".jsonl")]
assert len(listing) == 1 and listing[0].startswith("view-"), listing  # nothing else of the sessions folder
EOF
stop

# 9. interactive TUI through a pty
python3 "$HERE/tui.py" "$AWL" >"$W/tui.out" 2>&1 && ok "tui ($(grep -c '^ok' "$W/tui.out") checks)" || bad "tui" "$(grep FAIL "$W/tui.out")"

echo "e2e: $pass passed, $fail failed"
[ $fail -eq 0 ]
