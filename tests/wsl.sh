#!/bin/bash
# WSL-only sandbox escape checks: the ways out of awl's sandbox that exist only under Windows
# Subsystem for Linux (Windows interop, the Windows drives, WSLg). Same method as tests/sandbox.sh:
# a fake model asks for each escape through awl's real tools, and a probe prints ESCAPED-<name>
# only if it got through; INSIDE-<name> are positive controls that must appear.
#
# Every probe runs twice: once with AWL_SANDBOX=off (the control: can this machine show the
# escape at all?) and once sandboxed (the verdict). So each probe ends as one of
#   blocked   fires unsandboxed, not in the sandbox
#   ESCAPED   fires in the sandbox
#   untested  fires in neither: this machine cannot show it (interop off, no WSLg, ...)
# and "blocked" never means "nothing ran": a probe that did not run to its end in the sandbox
# (awl turns a command into a background job at its timeout) is a failure, not a pass.
#
# Usage: tests/wsl.sh [path/to/awl]        (docs/wsl.md)
#   WSL_REQUIRE="interop drvfs"  probe-name prefixes that must not end untested (CI sets it)
#   WSL_PLANT_HOME=1             also plant a probe file in the Windows profile's .ssh and .aws
#                                (CI; by hand the script only lists those folders if they exist)
#   WSL_SKIP_TUI=1               skip tests/tui.py
# Exit: 0 nothing escaped; 1 an escape or a failed control; 2 not WSL (nothing was tested);
#       3 nothing escaped but a required probe was untested.
# It writes only files it planted (awl-wsl-probe-* names) and removes them. The result block at
# the end is safe to paste: Windows user names are replaced by <user>.
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)

redact() { sed -E 's#(/mnt/[a-z]/Users/)[^/ :]+#\1<user>#g; s#/home/[^/ :]+#/home/<user>#g'; }
rel=$(uname -r)
if ! grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_DISTRO_NAME:-}" ] && [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]; then
  echo "wsl.sh: this is not WSL ($rel): nothing was tested"
  exit 2
fi
case $rel in *-Microsoft) kind=1 ;; *) kind=2 ;; esac
[ -x "$AWL" ] || { echo "wsl.sh: no awl binary at $AWL"; exit 1; }

mkdir -p "$HERE/../.zig-cache"
W=$(mktemp -d -p "$(realpath "$HERE/../.zig-cache")")
N=$$
planted=()   # files and folders this script created outside $W, removed on exit (deepest first)
cleanup() {
  # shellcheck disable=SC2046
  kill $(jobs -p) 2>/dev/null
  local i
  for ((i = ${#planted[@]} - 1; i >= 0; i--)); do
    if [ -d "${planted[i]}" ]; then rmdir "${planted[i]}" 2>/dev/null; else rm -f "${planted[i]}"; fi
  done
  rm -rf "$W"
}
trap cleanup EXIT
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS AWL_AGENTS AWL_MODE AWL_SANDBOX AWL_SANDBOX_NET AWL_SANDBOX_WRITE AWL_SANDBOX_SOCKETS AWL_NETWORK AWL_CTX_MODE
export XDG_STATE_HOME=$W/state XDG_CONFIG_HOME=/nonexistent
REAL_HOME=${HOME:-}
export HOME=$W/home
mkdir -p "$HOME/.ssh" "$W/proj"
TOK=WSLPROBE$N
echo "${TOK}HOME" >"$HOME/.ssh/id_probe"

pass=0
fail=0
untested=0
need=0
block=""
line() { block+="$1"$'\n'; echo "$1" | redact; }
ok() { line "ok        $1"; pass=$((pass + 1)); }
bad() { line "FAIL      $1: $2"; fail=$((fail + 1)); }

# run NAME DIR [VAR=value...]: one `awl -p` in DIR against the script $W/NAME.json. Leaves every
# tool result the model saw in $W/NAME.results and awl's own output in $W/NAME.out.
run() {
  local name=$1 dir=$2
  shift 2
  : >"$W/port"
  python3 "$HERE/fake_sse.py" "$W/${name%%.*}.json" --log "$W/$name.jsonl" >"$W/port" &
  local spid=$!
  for _ in $(seq 100); do [ -s "$W/port" ] && break; sleep 0.05; done
  (cd "$dir" && env AWL_URL="http://127.0.0.1:$(cat "$W/port")" "$@" timeout 900 "$AWL" -p probe) >"$W/$name.out" 2>&1
  echo "exit $?" >>"$W/$name.out"
  kill $spid 2>/dev/null
  wait $spid 2>/dev/null
  python3 - "$W/$name.jsonl" >"$W/$name.results" <<'EOF'
import json, sys
seen = []
for l in open(sys.argv[1]):
    for m in json.loads(l).get("messages", []):
        if m.get("role") == "tool" and m.get("content") not in seen:
            seen.append(m.get("content"))
print("\n".join(str(c) for c in seen))
EOF
}

bwrap_v=$(/usr/bin/bwrap --version 2>/dev/null || echo "not installed")
header="kernel: $rel
wsl: $kind   bwrap: $bwrap_v   awl: $("$AWL" --version 2>/dev/null | head -1)
user: uid $(id -u)   systemd: $([ -d /run/systemd/system ] && echo yes || echo no)   apparmor userns limit: $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo none)"

finish() {
  local rc=0
  [ $fail -eq 0 ] || rc=1
  [ $rc -eq 0 ] && [ $need -gt 0 ] && rc=3
  {
    echo
    echo "----- awl wsl result (paste from here) -----"
    echo "$header"
    printf '%s' "$block"
    echo "wsl: $pass ok, $fail failed, $untested untested; exit $rc"
    echo "----- end -----"
  } | redact
  exit $rc
}

# ---- WSL1: no user namespaces, so no sandbox. awl must refuse the model's commands and say why.
if [ $kind = 1 ]; then
  echo '[{"tool_calls":[{"name":"bash","arguments":{"command":"I=INSIDE; echo $I-ran"}}]},{"content":"Done."}]' >"$W/wsl1.json"
  run wsl1 "$W/proj"
  if grep -q 'INSIDE-ran' "$W/wsl1.results"; then
    bad "WSL1: fails closed" "the model's command ran: $(head -3 "$W/wsl1.results")"
  elif grep -qi 'sandbox' "$W/wsl1.results"; then
    ok "WSL1: fails closed (the model's command is refused)"
  else
    bad "WSL1: fails closed" "no command ran but no refusal either: $(head -3 "$W/wsl1.results" "$W/wsl1.out")"
  fi
  line "          awl said: $(grep -i -m1 'sandbox' "$W/wsl1.results" | cut -c1-200)"
  if grep -qiE 'WSL ?1|WSLv1' "$W/wsl1.results" "$W/wsl1.out"; then
    ok "WSL1: the refusal names WSL1"
  else
    bad "WSL1: the refusal names WSL1" "it should say WSL1 cannot run the sandbox and how to convert the distro (wsl --set-version <distro> 2)"
  fi
  finish
fi

# ---- WSL2 ----
[ -x /usr/bin/bwrap ] || { bad "bubblewrap installed" "no /usr/bin/bwrap: sudo apt install bubblewrap"; finish; }

# What this machine has (found from outside the sandbox).
CMD=$(ls /mnt/?/Windows/System32/cmd.exe 2>/dev/null | head -1)
PS=$(ls /mnt/?/Windows/System32/WindowsPowerShell/v1.0/powershell.exe 2>/dev/null | head -1)
DRV=$(awk '$3 ~ /^(9p|drvfs|virtiofs)$/ && $2 ~ /^\/mnt\/[a-z]$/ {print $2; exit}' /proc/mounts)
WH=""
if [ -n "$CMD" ]; then
  # the Windows profile folder, as a Linux path (needs interop; empty without it)
  WH=$(cd /mnt/c 2>/dev/null && timeout 30 "$CMD" /c 'echo %USERPROFILE%' 2>/dev/null </dev/null | tr -d '\r' | head -1)
  [ -n "$WH" ] && WH=$(wslpath -u "$WH" 2>/dev/null)
  [ -d "$WH" ] || WH=""
fi
header+="
interop: binfmt $([ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ] && echo registered || echo absent), WSL_INTEROP ${WSL_INTEROP:-unset}, /run/WSL sockets $(find /run/WSL -maxdepth 1 -type s 2>/dev/null | wc -l)
drives: ${DRV:-none} ($(awk -v d="$DRV" '$2 == d {print $3}' /proc/mounts | head -1)), Windows entries on PATH $(tr ':' '\n' <<<"$PATH" | grep -c '^/mnt/[a-z]/')
wslg: $([ -d /mnt/wslg ] && echo "/mnt/wslg, sockets $(find /mnt/wslg -maxdepth 3 -type s -not -path '/mnt/wslg/distro/*' 2>/dev/null | wc -l), distro view $([ -d /mnt/wslg/distro ] && echo yes || echo no)" || echo absent), /tmp/.X11-unix sockets $(find /tmp/.X11-unix -maxdepth 1 -type s 2>/dev/null | wc -l)"

# Planted files on the Windows drive: a folder of our own, and (WSL_PLANT_HOME=1) one file in the
# Windows profile's .ssh and .aws so those probes cannot pass by the folder not existing.
D=""
P=""
for base in "$DRV/Users/Public" "$WH"; do
  [ -n "$DRV" ] && [ -d "$base" ] && mkdir "$base/awl-wsl-probe-$N" 2>/dev/null || continue
  D=$base/awl-wsl-probe-$N
  P=$D/proj
  mkdir "$P"
  echo "${TOK}BASH" >"$D/secret.txt"
  echo "${TOK}READ" >"$D/secret-read.txt"
  echo "${TOK}GREP" >"$D/secret-grep.txt"
  planted+=("$D" "$P" "$D/secret.txt" "$D/secret-read.txt" "$D/secret-grep.txt" "$D/w-bash.txt" "$D/w-tool.txt" "$P/made.txt" "$P/tool.txt" "$P/w-sibling.txt" "$D/w-sibling.txt")
  break
done
if [ "${WSL_PLANT_HOME:-}" = 1 ] && [ -n "$WH" ]; then
  for d in .ssh .aws; do
    [ -d "$WH/$d" ] || { mkdir "$WH/$d" && planted+=("$WH/$d"); }
    echo "${TOK}WIN" >"$WH/$d/awl-wsl-probe-$N" && planted+=("$WH/$d/awl-wsl-probe-$N")
  done
fi

# The probes. Markers are put together at run time ($E-name), so a tool result that quotes the
# command cannot look like a hit.
P_CMD=$CMD P_PS=$PS P_D=${D:-/nonexistent} P_TOK=$TOK P_HOME=$HOME python3 - "$W" <<'PY'
import json, os, sys
W = sys.argv[1]
e = os.environ
CMD, PS, D, TOK, HOME = e["P_CMD"] or "/nonexistent", e["P_PS"] or "/nonexistent", e["P_D"], e["P_TOK"], e["P_HOME"]
win = ' 2>/dev/null </dev/null | tr -d "\\r" | grep -qx Windows_NT'  # real output of a Windows program
connect = r'''python3 - %s <<'EOF'
import glob, os, socket, stat, sys
for g in sys.argv[2:]:
    for p in glob.glob(g):
        for kind in (socket.SOCK_STREAM, socket.SOCK_SEQPACKET, socket.SOCK_DGRAM):
            try:
                if not stat.S_ISSOCK(os.stat(p).st_mode): break
                s = socket.socket(socket.AF_UNIX, kind); s.settimeout(3); s.connect(p)
                print("ESC" + "APED-" + sys.argv[1], p); break
            except OSError: pass
EOF'''
# (name, command, what it means when it fires, why it may be untested)
esc = [
    ("interop-cmd", 'timeout 30 %s /c "echo %%OS%%"%s && echo $E-interop-cmd' % (CMD, win),
     "cmd.exe runs on Windows, outside the sandbox, with the network", "Windows interop is off or cmd.exe was not found"),
    ("interop-sock", 'for s in $(ls /run/WSL/*_interop 2>/dev/null | head -3); do WSL_INTEROP=$s timeout 20 %s /c "echo %%OS%%"%s && echo $E-interop-sock && break; done; true' % (CMD, win),
     "cmd.exe runs once the command sets WSL_INTEROP itself to a socket in /run/WSL", "Windows interop is off"),
    ("init-interop", 'for s in "${WSL_INTEROP:-}" $(ls /run/WSL/*_interop 2>/dev/null | head -2); do export WSL_INTEROP=$s; for a in "%s" "%s cmd.exe"; do timeout 10 /init $a /c "echo %%OS%%"%s && echo $E-init-interop && break 2; done; done; true' % (CMD, CMD, win),
     "/init (the binfmt_misc handler) starts cmd.exe when called directly", "Windows interop is off, or /init does not take this form"),
    ("interop-powershell", "timeout 90 %s -NoProfile -NonInteractive -Command '$env:OS'%s && echo $E-interop-powershell" % (PS, win),
     "powershell.exe runs on Windows", "Windows interop is off or powershell.exe was not found"),
    ("interop-connect", connect % "interop-connect /run/WSL/*_interop",
     "the interop socket in /run/WSL accepts a connection", "no socket in /run/WSL"),
    ("interop-runwsl", 'ls /run/WSL 2>/dev/null | grep -q . && echo $E-interop-runwsl',
     "/run/WSL is listed", "no /run/WSL"),
    ("env-interop", '[ -n "${WSL_INTEROP:-}" ] && echo $E-env-interop',
     "the command's environment has WSL_INTEROP", "WSL_INTEROP is not set in this shell"),
    ("env-wslg", '[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}${PULSE_SERVER:-}" ] && echo $E-env-wslg',
     "the command's environment has DISPLAY, WAYLAND_DISPLAY or PULSE_SERVER", "WSLg sets none of them here"),
    ("winpath", 'case ":$PATH:" in *:/mnt/[a-z]/*) echo $E-winpath ;; esac',
     "PATH has Windows folders (/mnt/c/...)", "PATH has no Windows folder (appendWindowsPath off)"),
    ("winpath-exec", 'for c in cmd.exe powershell.exe wsl.exe explorer.exe clip.exe; do command -v $c >/dev/null && echo $E-winpath-exec && break; done; true',
     "a Windows program is found by bare name", "PATH has no Windows folder"),
    ("drvfs-read", 'grep -q %sBASH %s/secret.txt 2>/dev/null && echo $E-drvfs-read' % (TOK, D),
     "a planted file on the Windows drive is read", "no Windows drive is mounted"),
    ("drvfs-write", 'echo x 2>/dev/null >%s/w-bash.txt && echo $E-drvfs-write' % D,
     "a file on the Windows drive is written", "no Windows drive is mounted"),
    ("drvfs-ssh", 'for d in /mnt/?/Users/*/.ssh; do ls "$d" >/dev/null 2>&1 && echo $E-drvfs-ssh && break; done; true',
     "the Windows profile's .ssh is listed", "no .ssh in a Windows profile (WSL_PLANT_HOME=1 plants one)"),
    ("drvfs-aws", 'for d in /mnt/?/Users/*/.aws; do ls "$d" >/dev/null 2>&1 && echo $E-drvfs-aws && break; done; true',
     "the Windows profile's .aws is listed", "no .aws in a Windows profile (WSL_PLANT_HOME=1 plants one)"),
    ("drvfs-appdata", 'for d in /mnt/?/Users/*/AppData/Local; do ls "$d" >/dev/null 2>&1 && echo $E-drvfs-appdata && break; done; true',
     "the Windows profile's AppData (browser profiles, tokens) is listed", "no Windows profile is reachable"),
    ("wslg-distro", 'grep -q %sHOME /mnt/wslg/distro%s/.ssh/id_probe 2>/dev/null && echo $E-wslg-distro' % (TOK, HOME),
     "~/.ssh is read through /mnt/wslg/distro, a second view of the whole distro that the mask over ~/.ssh does not cover", "no /mnt/wslg/distro (WSLg off)"),
    ("wslg-sock", connect % "wslg-sock /mnt/wslg/* /mnt/wslg/.X11-unix/* /mnt/wslg/runtime-dir/* /mnt/wslg/runtime-dir/pulse/*",
     "a WSLg socket (X11, Wayland, PulseAudio) accepts a connection", "no WSLg socket (WSLg off or no desktop session)"),
    ("wslg-x11", connect % "wslg-x11 /tmp/.X11-unix/*",
     "the X11 socket in /tmp/.X11-unix accepts a connection", "no socket in /tmp/.X11-unix"),
]
inside = [
    ("write", 'echo made >made.txt && echo $I-$(cat made.txt | sed s/made/write/)'),
    ("tools", 'for c in python3 timeout grep sed ls; do command -v $c >/dev/null || echo MISSING-$c; done; echo $I-tools'),
]
# every probe ends with FINISHED-<name>: without it the sandboxed run proves nothing about that probe
calls = [{"name": "bash", "arguments": {"command": "E=ESCAPED I=INSIDE F=FINISHED; " + x[1] + "\necho $F-" + x[0], "timeout": 110}} for x in esc + inside]
turns = [{"tool_calls": calls[i:i + 10]} for i in range(0, len(calls), 10)]
# awl's in-process tools follow their own path rules, not the mount namespace
turns.append({"tool_calls": [
    {"name": "read", "arguments": {"path": D + "/secret-read.txt"}},
    {"name": "grep", "arguments": {"pattern": TOK + "GRE[P]", "path": D}},
    {"name": "write", "arguments": {"path": D + "/w-tool.txt", "content": "planted"}},
    {"name": "read", "arguments": {"path": "/mnt/wslg/distro" + HOME + "/.ssh/id_probe"}},
]})
turns.append({"content": "Done."})
json.dump(turns, open(W + "/probes.json", "w"))
tools = [
    ("tool-read-drvfs", "", "the read tool returns a planted file on the Windows drive", "no Windows drive is mounted"),
    ("tool-grep-drvfs", "", "the grep tool returns a planted file on the Windows drive", "no Windows drive is mounted"),
    ("tool-write-drvfs", "", "the write tool writes a file on the Windows drive", "no Windows drive is mounted"),
    ("wslg-tool-read", "", "the read tool returns ~/.ssh through /mnt/wslg/distro", "no /mnt/wslg/distro (WSLg off)"),
]
with open(W + "/probes.txt", "w") as f:
    for n, _, means, why in esc + tools:
        f.write("%s\t%s\t%s\n" % (n, means, why))
# A project on the Windows drive must keep working (a mask over the drive goes under it), and
# must still not reach its neighbours there.
json.dump([{"tool_calls": [
    {"name": "bash", "arguments": {"command": "E=ESCAPED I=INSIDE; echo made >made.txt && grep -q made made.txt && echo $I-drvproj"}},
    {"name": "bash", "arguments": {"command": "E=ESCAPED I=INSIDE; echo x 2>/dev/null >../w-sibling.txt && echo $E-drvproj-sibling"}},
    {"name": "write", "arguments": {"path": "tool.txt", "content": "fine"}},
]}, {"content": "Done."}], open(W + "/drvproj.json", "w"))
PY

# hits NAME: the probes that fired in run NAME, one name per line
hits() {
  local r=$W/$1.results
  grep -o 'ESCAPED-[a-z0-9-]*' "$r" | sed 's/^ESCAPED-//' | sort -u
  grep -q "${TOK}READ" "$r" && echo tool-read-drvfs
  grep -q "${TOK}GREP" "$r" && echo tool-grep-drvfs
  grep -q "${TOK}HOME" "$r" && echo wslg-tool-read
  [ -n "$D" ] && [ -e "$D/w-tool.txt" ] && echo tool-write-drvfs
  [ -n "$D" ] && rm -f "$D/w-tool.txt" "$D/w-bash.txt"
}
run probes.open "$W/proj" AWL_SANDBOX=off
hits probes.open >"$W/open.hits"
# awl filters the environment with the sandbox off too, so for these two the control is this shell
[ -n "${WSL_INTEROP:-}" ] && echo env-interop >>"$W/open.hits"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}${PULSE_SERVER:-}" ] && echo env-wslg >>"$W/open.hits"
rm -f "$W/proj/made.txt"
run probes "$W/proj"
hits probes >"$W/in.hits"

grep -q '^exit 0$' "$W/probes.out" && ok "awl ran the probes in the sandbox" || bad "awl ran the probes in the sandbox" "$(tail -4 "$W/probes.out" | tr '\n' ' ')"
for p in write tools; do
  grep -q "INSIDE-$p" "$W/probes.results" && ok "still works: $p" || bad "still works: $p" "missing: $(grep -i -m2 'sandbox\|bwrap' "$W/probes.results" "$W/probes.out" | cut -c1-300)"
done
grep MISSING- "$W/probes.results" && bad "probe tools present" "install them"
while IFS=$'\t' read -r name means why; do
  if grep -qx "$name" "$W/in.hits"; then
    line "ESCAPED   $name: $means"
    det=$(grep "ESCAPED-$name " "$W/probes.results" | head -4 | sed 's/^/          /')
    [ -z "$det" ] || line "$det"
    fail=$((fail + 1))
  elif grep -qx "$name" "$W/open.hits"; then
    case $name in
      tool-* | wslg-tool-*) fin=1 ;; # in-process tools return when they are done
      *) fin=$(grep -c "^FINISHED-$name\$" "$W/probes.results") ;;
    esac
    if [ "$fin" -gt 0 ]; then
      line "blocked   $name"
      pass=$((pass + 1))
    else
      bad "$name" "inconclusive: the probe did not run to its end in the sandbox"
    fi
  else
    line "untested  $name ($why)"
    untested=$((untested + 1))
    for r in ${WSL_REQUIRE:-}; do case $name in "$r"*) need=$((need + 1)) && line "          required by WSL_REQUIRE" ;; esac; done
  fi
done <"$W/probes.txt"

if [ -n "$P" ]; then
  run drvproj "$P"
  grep -q 'INSIDE-drvproj' "$W/drvproj.results" && ok "a project on the Windows drive: commands write in it" || bad "a project on the Windows drive: commands write in it" "$(head -3 "$W/drvproj.results" | cut -c1-300)"
  [ "$(cat "$P/tool.txt" 2>/dev/null)" = fine ] && ok "a project on the Windows drive: the write tool works" || bad "a project on the Windows drive: the write tool works" "no tool.txt"
  rm -f "$P/tool.txt"
  if grep -q 'ESCAPED-drvproj-sibling' "$W/drvproj.results"; then
    line "ESCAPED   drvproj-sibling: a project on the Windows drive writes next to itself"
    fail=$((fail + 1))
  else
    ok "a project on the Windows drive: no write outside it"
  fi
else
  line "untested  a project on the Windows drive (no writable Windows drive)"
  untested=$((untested + 1))
  for r in ${WSL_REQUIRE:-}; do [ "$r" = drvfs ] && need=$((need + 1)); done
fi

# The TUI through a Linux pty on the WSL kernel (not through conpty or Windows Terminal: tui.py
# opens its own pty, so the Windows side of the terminal is not exercised).
if [ "${WSL_SKIP_TUI:-}" = 1 ]; then
  line "untested  tui (WSL_SKIP_TUI=1)"
  untested=$((untested + 1))
else
  HOME=$REAL_HOME timeout 900 python3 "$HERE/tui.py" "$AWL" >"$W/tui.out" 2>&1
  tui_rc=$?
  if [ $tui_rc -eq 0 ]; then
    ok "tui.py under the WSL pty ($(grep -c '^ok' "$W/tui.out") checks)"
  else
    bad "tui.py under the WSL pty" "exit $tui_rc, $(grep -c '^ok' "$W/tui.out") ok; $(grep '^FAIL' "$W/tui.out" | head -5 | cut -c1-200 | tr '\n' ';') $(tail -2 "$W/tui.out" | cut -c1-200 | tr '\n' ' ')"
  fi
fi

[ $fail -eq 0 ] || cp "$W/probes.results" "${WSL_DUMP:-/dev/null}" 2>/dev/null
finish
