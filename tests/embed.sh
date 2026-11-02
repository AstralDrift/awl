#!/bin/bash
# What programs that run awl rely on (docs/embedding.md), held in place against
# tests/fake_sse.py. Usage: tests/embed.sh [path/to/awl]
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS AWL_AGENTS AWL_MODE AWL_SUMMARY AWL_NETWORK
pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# --version: one line on stdout, exit 0, the build.zig.zon version and a 7-digit commit
# (or "unknown" for a build without git).
ver=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$HERE/../build.zig.zon")
out=$("$AWL" --version 2>"$W/err")
rc=$?
[[ $rc -eq 0 && $out =~ ^awl\ ${ver//./\\.}\ \(([0-9a-f]{7}|unknown)\)$ && $(printf '%s\n' "$out" | wc -l) -eq 1 && ! -s $W/err ]] &&
  ok "--version: '$out'" || bad "--version" "rc=$rc out='$out' want 'awl $ver (<commit>)' err=$(cat "$W/err")"

# serve SCRIPT -> PORT, LOG (as in e2e.sh)
serve() {
  LOG=$W/req-$RANDOM.jsonl
  python3 "$HERE/fake_sse.py" "$1" --log "$LOG" >"$W/port" &
  SPID=$!
  for _ in $(seq 50); do [ -s "$W/port" ] && break; sleep 0.02; done
  PORT=$(cat "$W/port")
  : >"$W/port"
}
stop() { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; }

# run [VAR=value...] -- TASK: awl -p TASK the way an embedder runs it: no terminal, a cleared
# environment, AWL_KEY always set (empty here), a scratch HOME and state dir. A key file
# planted where awl's fallback would look must never be read. Sets RC, OUT, SESSION.
H=$W/home
mkdir -p "$H/.local/state/omarchy/local-ai" "$W/proj"
echo planted-key >"$H/.local/state/omarchy/local-ai/gateway.key"
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1") && shift; done
  shift
  rm -rf "$W/state"
  OUT=$(cd "$W/proj" && env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$H" XDG_STATE_HOME="$W/state" \
    AWL_URL="http://127.0.0.1:$PORT" AWL_KEY= AWL_MODE=auto AWL_MODEL=m "${envs[@]}" \
    "$AWL" -p "$1" </dev/null 2>"$W/err")
  RC=$?
  SESSION=$(ls "$W"/state/awl/sessions/*.jsonl 2>/dev/null | tail -n 1)
}
# py CODE: run a python check with LOG and SESSION as argv[1], argv[2]
# results: tool results without the budget line fresh mode (the default) ends each one with; raw keeps it.
py() { python3 -c "import json, re, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
lines = [json.loads(l) for l in open(sys.argv[2])] if sys.argv[2] else []
msgs = [m for m in lines if 'role' in m]
raw = [m['content'] for m in msgs if m['role'] == 'tool']
results = [re.sub(r'\n?\[time [^]]*\]\Z', '', r) for r in raw]
$1" "$LOG" "${SESSION:-}"; }

# 1. A -p run: exit 0, empty AWL_KEY sent as is (no key file fallback), the session file in
#    $XDG_STATE_HOME/awl/sessions, OpenAI-style messages, and the bash result endings.
cat >"$W/one.json" <<'EOF'
[{"content":"Working.","tool_calls":[{"name":"bash","arguments":{"command":"printf hi"}},{"name":"bash","arguments":{"command":"echo out; exit 3"}},{"name":"bash","arguments":{"command":"true"}}]},
 {"tool_calls":[{"name":"write","arguments":{"path":"new.txt","content":"x\n"}},{"name":"nope","arguments":{}},{"name":"bash","arguments":{"cmd":"ls"}},{"name":"bash","arguments":"{\"command\": \"ls"}]},
 {"content":"All done."}]
EOF
serve "$W/one.json"
run -- "do it"
[ $RC -eq 0 ] && ok "-p: exit 0 when the model finishes" || bad "-p exit" "rc=$RC $(cat "$W/err")"
[ "$OUT" = $'Working.\nAll done.' ] && ok "-p: stdout is the model's text, one reply per line, the final reply last" || bad "-p stdout" "$OUT"
[[ $SESSION == "$W"/state/awl/sessions/*.jsonl ]] && ok "session file in \$XDG_STATE_HOME/awl/sessions/" || bad "session path" "'$SESSION' $(find "$W/state" "$H/.local/state" -name '*.jsonl')"
py '
assert all(r["_auth"].strip() == "Bearer" for r in reqs), [r["_auth"] for r in reqs]  # the server trims the space
' && ok "AWL_KEY set but empty: sent as is, the key file is never read" || bad "empty AWL_KEY" "see above"
py '
meta = lines[0]
assert set(meta) >= {"awl", "model", "cwd"} and meta["model"] == "m", meta
assert [m["role"] for m in msgs] == ["user", "assistant", "tool", "tool", "tool", "assistant", "tool", "tool", "tool", "tool", "assistant"], [m["role"] for m in msgs]
a = msgs[1]
assert a["content"] == "Working." and len(a["tool_calls"]) == 3, a
c = a["tool_calls"][1]
assert c["type"] == "function" and c["function"]["name"] == "bash", c
assert json.loads(c["function"]["arguments"]) == {"command": "echo out; exit 3"}, c
assert [m["tool_call_id"] for m in msgs[2:5]] == [x["id"] for x in a["tool_calls"]], msgs[2:5]
assert msgs[-1] == {"role": "assistant", "content": "All done."} or msgs[-1]["content"] == "All done.", msgs[-1]
' && ok "session lines: meta first, assistant tool_calls, tool messages with tool_call_id" || bad "session format" "see above"
py '
assert results[0] == "hi", repr(results[0])
assert all(re.search(r"\n\[time \d+s(, context \S+ of \S+)?\]\Z", r) for r in raw), raw  # docs/embedding.md: the budget line
assert results[1] == "out\n\n[exit 3]", repr(results[1])
assert results[2] == "(no output)", repr(results[2])
assert results[3].startswith("wrote ") or "new.txt" in results[3], repr(results[3])
assert results[4] == "unknown tool: nope", repr(results[4])
assert results[5].startswith("invalid arguments for bash: missing command"), repr(results[5])
assert results[6] == "invalid arguments for bash: not valid JSON (was the call cut off?)", repr(results[6])
' && ok "bash results: output, [exit N] last line, (no output); refusals: unknown tool:, invalid arguments for; budget line last" || bad "result endings" "see above"
stop

# 2. Without AWL_KEY the key file is the fallback (what embedders avoid by always setting it).
serve "$W/one.json"
OUT=$(cd "$W/proj" && env -i PATH=/usr/bin:/bin HOME="$H" XDG_STATE_HOME="$W/state" AWL_URL="http://127.0.0.1:$PORT" AWL_MODE=auto AWL_MODEL=m "$AWL" -p x </dev/null 2>&1)
py 'assert reqs[0]["_auth"] == "Bearer planted-key", reqs[0]["_auth"]' && ok "AWL_KEY unset: the key file under \$HOME is used" || bad "key fallback" "see above"
stop

# 3. Exit status: the step limit is 1 (after one final report with tools off), and the
#    model was told how many steps were left; an unreachable model is 1; bad settings are 2.
echo '[{"tool_calls":[{"name":"bash","arguments":{"command":"true"}}]}]' >"$W/loop.json"
serve "$W/loop.json"
run AWL_MAX_STEPS=10 -- "loop"
[ $RC -eq 1 ] && ok "step limit: exit 1" || bad "step limit exit" "rc=$RC"
py '
assert len(reqs) == 11 and reqs[-1].get("tool_choice") == "none", (len(reqs), reqs[-1].get("tool_choice"))
assert results[8].startswith("(no output)\n[awl: you have made this exact call 9 times") and results[8].endswith("\n[awl: 1 steps are left in this run. Stop checking and polishing: finish the essential work, then end with your final report.]"), repr(results[8])
' && ok "step limit: wrap-up note on a result, then one report request with tool_choice none" || bad "step limit" "see above"
stop
PORT=1
run -- "x"
[ $RC -eq 1 ] && ok "model unreachable: exit 1" || bad "unreachable exit" "rc=$RC"
run AWL_MODE=yolo -- "x"
[ $RC -eq 2 ] && ok "bad setting (AWL_MODE=yolo): exit 2" || bad "bad setting exit" "rc=$RC"

# 4. Plan mode, timeouts, background jobs and their limit, and the no-terminal network refusal.
cat >"$W/more.json" <<'EOF'
[{"tool_calls":[{"name":"bash","arguments":{"command":"sleep 5","timeout":1}},{"name":"bash","arguments":{"command":"true","background":true}},{"name":"bash","arguments":{"command":"curl https://example.com","network":true}}]},
 {"tool_calls":[{"name":"bash","arguments":{"command":"sleep 0.5"}}]},
 {"tool_calls":[{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 9","background":true}}]},
 {"tool_calls":[{"name":"bash","arguments":{"command":"sleep 9","background":true}},{"name":"bash","arguments":{"command":"sleep 5","timeout":1}}]},
 {"content":"ok"}]
EOF
serve "$W/more.json"
run -- "more"
py '
import re
# still running at its timeout: it goes on as a background job
assert re.search(r"\n\[still running after 1 s: it continues as background job 1 \(pid \d+\); its output goes on in /tmp/awl-\d+-\d+\.log\. ", results[0]), repr(results[0])
assert results[1].startswith("started background job 2 (pid "), repr(results[1])
assert results[2].startswith("not run: the network is off in the sandbox and only the user can approve"), repr(results[2])
# reaped at the top of the next tool result after the job ends (timing decides which)
assert any(re.match(r"\[background job 2 \(true\) exited with code 0; output in /tmp/awl-\d+-job2\.log\]\n", r) for r in results[3:]), results[3:5]
assert results[-2] == "too many background jobs (16); stop one with kill first", repr(results[-2])
# with the job table full, a command still running at its timeout is killed
assert results[-1].endswith("\n[timed out after 1 s; process group killed]"), repr(results[-1])
' && ok "timeout continues as a job, background job start and exit notes, job limit, timeout kill when full, network refused without a terminal" || bad "jobs and refusals" "see above"
stop
echo '[{"tool_calls":[{"name":"write","arguments":{"path":"p.txt","content":"x"}}]},{"content":"ok"}]' >"$W/plan.json"
serve "$W/plan.json"
run AWL_MODE=plan -- "plan"
py 'assert results[0].startswith("Plan mode: files are read-only."), repr(results[0])' && ok "AWL_MODE=plan: write refused with 'Plan mode:'" || bad "plan mode" "see above"
stop

# 5. The user-level AGENTS.md: $XDG_CONFIG_HOME/awl/AGENTS.md, else $HOME/.config/awl/AGENTS.md.
mkdir -p "$H/.config/awl" "$W/xdg/awl"
echo "HOME-RULE-7" >"$H/.config/awl/AGENTS.md"
echo "XDG-RULE-9" >"$W/xdg/awl/AGENTS.md"
echo '[{"content":"ok"}]' >"$W/hi.json"
serve "$W/hi.json"
run -- "hi"
py 's = reqs[0]["messages"][0]["content"]; assert "HOME-RULE-7" in s, s[-300:]' && ok "user AGENTS.md from \$HOME/.config/awl" || bad "HOME AGENTS.md" "see above"
run XDG_CONFIG_HOME="$W/xdg" -- "hi"
py 's = reqs[-1]["messages"][0]["content"]; assert "XDG-RULE-9" in s and "HOME-RULE-7" not in s' && ok "XDG_CONFIG_HOME wins over \$HOME/.config" || bad "XDG AGENTS.md" "see above"
stop
rm -rf "$H/.config"

# 6. AWL_NETWORK=off: a command that asks for the network is refused without asking, and the
#    result says why; it also beats AWL_SANDBOX_NET=on, so no command shares the host network.
python3 "$HERE/fake_sse.py" "$W/hi.json" >"$W/tport" & # a host port for commands to try
TPID=$!
for _ in $(seq 50); do [ -s "$W/tport" ] && break; sleep 0.02; done
TPORT=$(cat "$W/tport")
cat >"$W/net.json" <<EOF
[{"tool_calls":[{"name":"bash","arguments":{"command":"curl -sI https://example.com","network":true}},{"name":"bash","arguments":{"command":"(exec 3<>/dev/tcp/127.0.0.1/$TPORT) 2>/dev/null && echo reached || echo blocked"}}]},
 {"content":"ok"}]
EOF
serve "$W/net.json"
run AWL_NETWORK=off AWL_SANDBOX_NET=on -- "net"
py '
assert results[0].startswith("not run: AWL_NETWORK=off: commands cannot use the network in this session"), repr(results[0])
assert results[1].strip() == "blocked", repr(results[1])
s = reqs[0]["messages"][0]["content"]
assert "AWL_NETWORK=off" in s, s[-400:]
' && ok "AWL_NETWORK=off: network commands refused with a reason, AWL_SANDBOX_NET=on overruled, the model is told" || bad "AWL_NETWORK=off" "see above"
stop
serve "$W/net.json"
run AWL_SANDBOX_NET=on -- "net"
py 'assert results[1].strip() == "reached", repr(results[1])' && ok "control: AWL_SANDBOX_NET=on alone shares the host network" || bad "net control" "see above"
stop
kill $TPID 2>/dev/null
wait $TPID 2>/dev/null

# 7. AWL_SUMMARY=<path>: one JSON object when a -p run ends (docs/embedding.md, "Run summary").
sumpy() { python3 -c "import json, sys
s = json.load(open(sys.argv[1]))
assert s['version'] == 1, s
assert set(s) - {'error'} == {'version', 'awl', 'status', 'exit', 'steps', 'tool_calls', 'commands', 'files_written', 'session'}, sorted(s)
outcomes = {'exit', 'timed_out', 'interrupted', 'background', 'not_run'}
for c in s['commands']:
    assert len(set(c) & outcomes) == 1 and set(c) - outcomes == {'command'}, c
    if 'not_run' in c:
        r = c['not_run']
        assert isinstance(r, str) and 0 < len(r) <= 300 and '\n' not in r, repr(r)
$1" "$W/sum.json"; }
serve "$W/one.json"
rm -f "$W/sum.json"
run AWL_SUMMARY="$W/sum.json" -- "do it"
sumpy "
assert s['status'] == 'done' and s['exit'] == 0 and s['steps'] == 3, s
assert s['awl'] == '$("$AWL" --version | cut -c5-)', s['awl']
assert s['tool_calls'] == {'bash': 5, 'write': 1, 'nope': 1}, s['tool_calls']
cs = s['commands']
assert cs[:3] == [{'command': 'printf hi', 'exit': 0}, {'command': 'echo out; exit 3', 'exit': 3}, {'command': 'true', 'exit': 0}], cs
assert cs[3]['command'] is None and cs[3]['not_run'].startswith('invalid arguments for bash'), cs[3]
assert cs[4]['command'] is None and 'not valid JSON' in cs[4]['not_run'], cs[4]
assert s['files_written'] == ['new.txt'], s['files_written']
assert s['session'] == '$SESSION', s['session']
assert 'error' not in s, s
" && ok "AWL_SUMMARY: done, steps, tool counts, each command's exit, files written, session path" || bad "AWL_SUMMARY done" "$(cat "$W/sum.json")"
stop
serve "$W/more.json"
run AWL_SUMMARY="$W/sum.json" -- "more"
sumpy "
cs = s['commands']
assert cs[0] == {'command': 'sleep 5', 'background': 1}, cs[0]  # still running at its timeout: moved to a job
assert cs[1] == {'command': 'true', 'background': 2}, cs[1]
assert cs[2]['command'] == 'curl https://example.com' and 'network' in cs[2]['not_run'], cs[2]
assert cs[3] == {'command': 'sleep 0.5', 'exit': 0}, cs[3]
assert any(c['command'] == 'sleep 9' and 'background jobs' in c.get('not_run', '') for c in cs), cs
assert cs[-1] == {'command': 'sleep 5', 'timed_out': True}, cs[-1]  # the job table was full: killed
" && ok "AWL_SUMMARY: moved to a job, started as a job, exit, not-run reasons, timed out" || bad "AWL_SUMMARY outcomes" "$(cat "$W/sum.json")"
stop
serve "$W/loop.json"
run AWL_SUMMARY="$W/sum.json" AWL_MAX_STEPS=10 -- "loop"
sumpy "assert s['status'] == 'step_limit' and s['exit'] == 1 and s['steps'] == 11 and len(s['commands']) == 10, (s['status'], s['steps'])" && ok "AWL_SUMMARY: step_limit, exit 1" || bad "AWL_SUMMARY step limit" "$(head -c 300 "$W/sum.json")"
stop
PORT=1
run AWL_SUMMARY="$W/sum.json" -- "x"
sumpy "assert s['status'] == 'error' and s['exit'] == 1 and 'cannot reach the model' in s['error'], s" && ok "AWL_SUMMARY: error with its message, exit 1" || bad "AWL_SUMMARY error" "$(cat "$W/sum.json")"
run AWL_SUMMARY="$W/sum.json" AWL_MODE=yolo -- "x"
sumpy "assert s['status'] == 'error' and s['exit'] == 2 and s['steps'] == 0 and 'AWL_MODE' in s['error'], s" && ok "AWL_SUMMARY: bad setting is an error, exit 2" || bad "AWL_SUMMARY exit 2" "$(cat "$W/sum.json")"
serve "$W/hi.json"
rm -f "$W/sum.json"
run -- "hi"
[ ! -e "$W/sum.json" ] && ok "no AWL_SUMMARY: no summary file" || bad "summary without AWL_SUMMARY" "file written"
run AWL_SUMMARY=/nonexistent/dir/sum.json -- "hi"
[ $RC -eq 0 ] && ok "AWL_SUMMARY in a missing directory: the run still exits 0" || bad "unwritable AWL_SUMMARY" "rc=$RC"
stop

echo "embed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
