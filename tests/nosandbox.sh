#!/bin/bash
# What awl does without a working sandbox: it never runs the model's commands unsandboxed on
# its own. Usage: tests/nosandbox.sh [path/to/awl] [off blocked missing]
#   off      AWL_SANDBOX=off: the user's choice; commands run, the env allowlist still applies
#   blocked  bwrap is there but cannot start (user namespaces refused): commands are refused
#   missing  no /usr/bin/bwrap (run this one on a host without bubblewrap): commands are refused
# Default: off blocked.
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
shift
[ $# -gt 0 ] || set -- off blocked
mkdir -p "$HERE/../.zig-cache"
W=$(mktemp -d -p "$(realpath "$HERE/../.zig-cache")")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS AWL_AGENTS AWL_MODE AWL_SANDBOX AWL_SANDBOX_NET AWL_SANDBOX_WRITE AWL_NETWORK
export XDG_STATE_HOME=$W/state XDG_CONFIG_HOME=/nonexistent HOME=$W/home PROBE_SECRET_TOKEN=hunter2
pass=0
fail=0
skips=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
skip() { echo "skip $1"; skips=$((skips + 1)); }
mkdir -p "$HOME/.ssh" "$W/proj"
echo SECRETKEY >"$HOME/.ssh/id_probe"
git -C "$W/proj" init -q
echo "needle here" >"$W/proj/file.txt"

# tool_run [VAR=val...] [-- wrapper...]: one awl -p run of $CALLS in the project; prints the tool results
tool_run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  printf '[{"tool_calls":[%s]},{"content":"ok"}]' "$CALLS" >"$W/tool.json"
  python3 "$HERE/fake_sse.py" "$W/tool.json" --log "$W/tool.jsonl" >"$W/tport" &
  local tpid=$!
  for _ in $(seq 50); do [ -s "$W/tport" ] && break; sleep 0.02; done
  (cd "$W/proj" && env AWL_URL="http://127.0.0.1:$(cat "$W/tport")" "${envs[@]}" "$@" "$AWL" -p tools >"$W/out" 2>&1)
  kill $tpid; wait $tpid 2>/dev/null
  : >"$W/tport"
  python3 -c 'import json,sys; print("\n".join(x["content"] for x in [json.loads(l) for l in open(sys.argv[1])][-1]["messages"] if x["role"] == "tool"))' "$W/tool.jsonl" 2>/dev/null
  rm -f "$W/tool.jsonl"
}
CALLS='{"name":"bash","arguments":{"command":"echo ran >'"$W"'/ran.txt; echo BASH-ran; env | grep -c PROBE_SECRET_TOKEN"}},
{"name":"bash","arguments":{"command":"echo bg >'"$W"'/bg.txt","background":true}},
{"name":"grep","arguments":{"pattern":"needle","path":"."}},
{"name":"find","arguments":{"pattern":"file"}},
{"name":"read","arguments":{"path":"file.txt"}},
{"name":"read","arguments":{"path":"'"$HOME"'/.ssh/id_probe"}},
{"name":"write","arguments":{"path":"'"$W"'/outside.txt","content":"x"}},
{"name":"write","arguments":{"path":"inside.txt","content":"x"}}'
reset() { rm -f "$W/ran.txt" "$W/bg.txt" "$W/outside.txt" "$W/proj/inside.txt"; }

# Commands refused, nothing ran; the file tools keep their rules.
refused() { # NAME REASON-PATTERN
  sleep 0.3 # a background job, had one started, would have written by now
  [ ! -e "$W/ran.txt" ] && [ ! -e "$W/bg.txt" ] && ! grep -q 'BASH-ran\|needle here:' <<<"$got" && ok "$1: no command ran (bash, background, grep, find)" || bad "$1: a command ran" "$got"
  [ "$(grep -c "$2" <<<"$got")" -ge 3 ] && ok "$1: each refusal says why and what the user can do" || bad "$1: refusal text" "$got"
  grep -q '1→needle here' <<<"$got" && ! grep -q SECRETKEY <<<"$got" && [ ! -e "$W/outside.txt" ] && [ -e "$W/proj/inside.txt" ] && ok "$1: read/write still follow the path rules" || bad "$1: path rules" "$got"
}

for mode in "$@"; do
  reset
  case $mode in
  off)
    got=$(tool_run AWL_SANDBOX=off)
    sleep 0.3
    [ -e "$W/ran.txt" ] && [ -e "$W/bg.txt" ] && grep -q BASH-ran <<<"$got" && grep -q 'needle here' <<<"$got" && ok "AWL_SANDBOX=off: commands run" || bad "AWL_SANDBOX=off: commands run" "$got"
    grep -qx 0 <<<"$got" && ok "AWL_SANDBOX=off: the environment allowlist still applies" || bad "AWL_SANDBOX=off: env" "$got"
    [ -e "$W/outside.txt" ] && grep -q SECRETKEY <<<"$got" && ok "AWL_SANDBOX=off: no path rules (as documented)" || bad "AWL_SANDBOX=off: path rules" "$got"
    ;;
  blocked)
    # An outer sandbox that forbids nested user namespaces: what a container or a stock
    # Ubuntu 24.04 (AppArmor) does to bubblewrap.
    # shellcheck disable=SC2016
    block='echo 0 >/proc/sys/user/max_user_namespaces && exec "$@"'
    if unshare -Ur sh -c "$block" sh true 2>/dev/null; then
      got=$(tool_run -- unshare -Ur sh -c "$block" sh)
      refused "sandbox cannot start" 'not run: the sandbox did not start'
      grep -q 'AWL_SANDBOX=off' <<<"$got" && ok "sandbox cannot start: awl names AWL_SANDBOX=off and does not switch to it" || bad "sandbox cannot start: hint" "$got"
    elif [ -x /usr/bin/bwrap ] && ! /usr/bin/bwrap --ro-bind / / true 2>/dev/null; then
      got=$(tool_run) # bubblewrap is already blocked on this host: the real thing
      refused "sandbox cannot start (this host)" 'not run: the sandbox did not start'
    else
      skip "blocked: cannot forbid nested user namespaces here (unshare -Ur)"
    fi
    ;;
  missing)
    if [ -e /usr/bin/bwrap ]; then
      bad "missing" "this host has /usr/bin/bwrap; run this mode where bubblewrap is not installed"
    else
      got=$(tool_run)
      refused "no bubblewrap" 'not run: awl runs the model.s commands in a bubblewrap sandbox and /usr/bin/bwrap is missing'
    fi
    ;;
  *) bad "mode" "unknown: $mode" ;;
  esac
done
echo "nosandbox: $pass passed, $fail failed, $skips skipped"
[ $skips -eq 0 ] || [ "${CI:-}" != true ] || { echo "FAIL $skips skipped under CI"; fail=$((fail + 1)); }
[ $fail -eq 0 ]
