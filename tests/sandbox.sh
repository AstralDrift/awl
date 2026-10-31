#!/bin/bash
# Sandbox escape checks: a fake model asks for each escape through awl's real tools.
# Each probe prints ESCAPED-<name> only if it got through; positive controls print
# INSIDE-<name> and must appear, so the test cannot pass by nothing running.
# Usage: tests/sandbox.sh [path/to/awl]
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
[ -x /usr/bin/bwrap ] || { echo "skip: no /usr/bin/bwrap"; exit 0; }
# Not under /tmp: the symlink check needs a home that is outside every writable place.
mkdir -p "$HERE/../.zig-cache"
W=$(mktemp -d -p "$(realpath "$HERE/../.zig-cache")")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS AWL_AGENTS AWL_MODE AWL_SANDBOX AWL_SANDBOX_NET AWL_SANDBOX_WRITE
export XDG_STATE_HOME=$W/state XDG_CONFIG_HOME=/nonexistent
export PROBE_SECRET_TOKEN=hunter2
pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# A fake home with a secret, and a git project with instruction files.
export HOME=$W/home
mkdir -p "$HOME/.ssh" "$W/proj/.agents/skills/demo"
echo SECRETKEY >"$HOME/.ssh/id_probe"
echo "export X=1" >"$HOME/.bashrc_probe"
cd "$W/proj"
git init -q
echo "# rules" >AGENTS.md
printf -- '---\nname: demo\ndescription: d\n---\n' >.agents/skills/demo/SKILL.md
ln -s .git/config linkcfg
ln -s "$HOME/.bashrc_probe" linkrc
ln -s "$HOME/.ssh/id_probe" linkssh
cp .git/config "$W/config.before"
# Another session (another project's, say) and another awl's session view: the model must see neither.
mkdir -p "$XDG_STATE_HOME/awl/sessions"
echo '{"role":"tool","tool_call_id":"c","content":"OTHERSESSION-hunter3"}' >"$XDG_STATE_HOME/awl/sessions/20200101-000000-1.jsonl"
echo 'OTHERVIEW-hunter4' >"$XDG_STATE_HOME/awl/sessions/view-1.txt"

bash_call() { python3 -c 'import json,sys; print(json.dumps({"name":"bash","arguments":{"command":sys.argv[1]}}))' "$1"; }
{
  echo '[{"tool_calls":['
  i=0
  for c in \
    'curl -s --max-time 4 -o /dev/null https://example.com && echo ESCAPED-net' \
    'curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$(cat "'"$W"'/port")/v1/models" && echo ESCAPED-hostlocal' \
    'ip route get 169.254.169.254 >/dev/null 2>&1 && echo ESCAPED-metadata' \
    'unshare -Ur true 2>/dev/null && echo ESCAPED-userns' \
    'busctl --user list >/dev/null 2>&1 && echo ESCAPED-dbus' \
    'test -S /run/user/$(id -u)/bus && echo ESCAPED-runuser' \
    'for f in $(find /tmp -maxdepth 2 -type s 2>/dev/null); do test -S "$f" && echo "ESCAPED-tmpsock $f"; done; true' \
    'git config core.fsmonitor "echo pwned" 2>/dev/null && echo ESCAPED-gitconfig' \
    'touch .git/hooks/pre-commit 2>/dev/null && echo ESCAPED-githooks' \
    'echo x 2>/dev/null >>AGENTS.md && echo ESCAPED-agentsmd' \
    'echo x 2>/dev/null >>.agents/skills/demo/SKILL.md && echo ESCAPED-skills' \
    'env | grep -q PROBE_SECRET_TOKEN && echo ESCAPED-env' \
    'grep -q SECRETKEY ~/.ssh/id_probe 2>/dev/null && echo ESCAPED-sshbash' \
    'grep -a -l hunter2 /proc/*/environ 2>/dev/null | grep -q . && echo ESCAPED-procenv' \
    'cat "$XDG_STATE_HOME"/awl/sessions/*.jsonl 2>/dev/null | grep -q hunter3 && echo ESCAPED-sessions' \
    'cat "$XDG_STATE_HOME"/awl/sessions/view-1.txt 2>/dev/null | grep -q hunter4 && echo ESCAPED-otherview' \
    'for f in "$XDG_STATE_HOME"/awl/sessions/view-*.txt; do echo x 2>/dev/null >>"$f" && echo ESCAPED-viewwrite; done; true' \
    'grep -q "^{\"n\":2,\"role\":\"user\"}" "$XDG_STATE_HOME"/awl/sessions/view-*.txt && echo INSIDE-view; echo VIEWPATH "$XDG_STATE_HOME"/awl/sessions/view-*.txt' \
    'for c in curl ip unshare busctl git find; do command -v $c >/dev/null || echo MISSING-$c; done; echo INSIDE-tools' \
    'echo made >made.txt && echo INSIDE-$(cat made.txt)' \
    'f=/tmp/awl-sbx-$$; echo t >$f && rm $f && echo INSIDE-tmp' \
    'git add made.txt && git -c user.name=t -c user.email=t@t commit -qm x && echo INSIDE-git'; do
    # awl runs at most 16 tool calls per turn
    i=$((i + 1))
    [ $((i % 12)) -eq 0 ] && echo '{"name":"todo","arguments":{"items":[]}}]},{"tool_calls":['
    bash_call "$c"
    echo ,
  done
  echo '{"name":"todo","arguments":{"items":[]}}]},{"tool_calls":['
  cat <<EOF
{"name":"bash","arguments":{"command":"curl -s --max-time 4 -o /dev/null https://example.com && echo ESCAPED-netflag","network":true}},
{"name":"read","arguments":{"path":"$HOME/.ssh/id_probe"}},
{"name":"read","arguments":{"path":"linkssh"}},
{"name":"grep","arguments":{"pattern":"SECRETKEY","path":"$HOME/.ssh"}},
{"name":"read","arguments":{"path":"$XDG_STATE_HOME/awl/sessions/20200101-000000-1.jsonl"}},
{"name":"read","arguments":{"path":"$XDG_STATE_HOME/awl/sessions/view-1.txt"}},
{"name":"grep","arguments":{"pattern":"OTHERSESSION-hunter[3]|OTHERVIEW-hunter[4]","path":"$XDG_STATE_HOME/awl/sessions"}},
{"name":"read","arguments":{"path":"\$VIEW","limit":2}},
{"name":"write","arguments":{"path":".git/config","content":"[core]\\n\\tfsmonitor = echo pwned\\n"}},
{"name":"write","arguments":{"path":"AGENTS.md","content":"planted"}},
{"name":"write","arguments":{"path":"linkcfg","content":"planted"}},
{"name":"write","arguments":{"path":"linkrc","content":"planted"}},
{"name":"write","arguments":{"path":"ok.txt","content":"fine"}}
]},{"tool_calls":[
{"name":"bash","arguments":{"command":"python3 -m http.server 8765 --bind 127.0.0.1","background":true}},
{"name":"bash","arguments":{"command":"for i in \$(seq 50); do curl -s -o /dev/null http://127.0.0.1:8765/ && echo INSIDE-shared && break; sleep 0.1; done"}},
{"name":"bash","arguments":{"command":"echo PGIDS \$(ps -eo pgid=,args= | grep '[h]ttp.server 8765' | awk '{print \$1}')"}}
]},{"content":"Done."}]
EOF
} >"$W/script.json"

LOG=$W/req.jsonl
python3 "$HERE/fake_sse.py" "$W/script.json" --log "$LOG" >"$W/port" &
for _ in $(seq 50); do [ -s "$W/port" ] && break; sleep 0.02; done
export AWL_URL=http://127.0.0.1:$(cat "$W/port")
"$AWL" -p "probe" >"$W/out" 2>&1 || bad "awl exit" "$(tail -5 "$W/out")"

results=$(python3 -c '
import json, sys
m = [json.loads(l) for l in open(sys.argv[1])][-1]["messages"]
print("\n".join("[%s] %s" % (i, x["content"]) for i, x in enumerate(m) if x["role"] == "tool"))' "$LOG")
for p in net hostlocal netflag metadata userns dbus runuser tmpsock gitconfig githooks agentsmd skills env sshbash procenv sessions otherview viewwrite; do
  grep -q "ESCAPED-$p" <<<"$results" && bad "blocks $p" "got through" || ok "blocks $p"
done
for p in tools made tmp git shared view; do
  grep -q "INSIDE-$p" <<<"$results" && ok "still works: $p" || bad "still works: $p" "missing"
done
grep -q "only the user can approve a command that needs it" <<<"$results" && ok "network: true refused without a terminal" || bad "network: true refused without a terminal" "no refusal"
job_pid=$(grep -o 'started background job 1 (pid [0-9]*' <<<"$results" | grep -o '[0-9]*$')
grep -q "PGIDS.*\b$job_pid\b" <<<"$results" && ok "job pid is the group the model can kill" || bad "job pid is the group the model can kill" "pid $job_pid; $(grep PGIDS <<<"$results")"
grep MISSING- <<<"$results" && bad "probe tools present" "install them" || ok "probe tools present"
grep -q 'OTHERSESSION-hunter3\|OTHERVIEW-hunter4' <<<"$results" && bad "read/grep hide other sessions" "$(grep 'hunter[34]' <<<"$results" | head -3)" || ok "read/grep hide other sessions"
grep -q '1→{"n":2,"role":"user"}$' <<<"$results" && ok "read shows this session's view" || bad "read shows this session's view" "$(grep -A2 'view-' <<<"$results" | head -5)"
grep -q SECRETKEY <<<"$results" && bad "read/grep hide ~/.ssh" "$(grep SECRETKEY <<<"$results" | head -3)" || ok "read/grep hide ~/.ssh"
cmp -s .git/config "$W/config.before" && ok ".git/config unchanged" || bad ".git/config unchanged" "$(cat .git/config)"
[ "$(cat AGENTS.md)" = "# rules" ] && ok "AGENTS.md unchanged" || bad "AGENTS.md unchanged" "$(cat AGENTS.md)"
[ "$(cat "$HOME/.bashrc_probe")" = "export X=1" ] && ok "symlink out of project refused" || bad "symlink out of project refused" "$(cat "$HOME/.bashrc_probe")"
[ "$(cat ok.txt 2>/dev/null)" = fine ] && ok "write in project works" || bad "write in project works" "no ok.txt"

echo "sandbox: $pass passed, $fail failed"
[ $fail -eq 0 ] || { echo "$results" >"${SANDBOX_DUMP:-/dev/null}"; exit 1; }
