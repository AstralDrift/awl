#!/bin/bash
# macOS sandbox probes (spike): the escape checks of tests/sandbox.sh, run under sandbox-exec
# with spike/macos/awl.sb instead of through awl and bubblewrap. Prints one line per claim:
#   ok    the claim holds
#   FAIL  it does not (a probe got through, or something that must work does not)
#   DIFF  it holds in a different shape on macOS, or cannot be met (the line says which)
#   skip  could not be checked on this machine
# Everything it touches is a fake home and project under .zig-cache/; no real secret is read
# or printed. It makes one request to https://example.com (the network checks).
# Usage: bash spike/macos/probes.sh     (not inside another Seatbelt sandbox: they do not nest)
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo "skip: macOS only"; exit 0; }
if ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  echo "cannot run: sandbox-exec refused (this shell is already inside a Seatbelt sandbox, and they do not nest)."
  echo "Run it from a plain terminal:  bash spike/macos/probes.sh"
  exit 2
fi
mkdir -p "$HERE/../../.zig-cache"
W=$(mktemp -d "$(cd "$HERE/../../.zig-cache" && pwd -P)/probe.XXXXXX") # not under any writable place
[ -d "$W" ] || { echo "mktemp failed"; exit 1; }
REAL_AUTH_SOCK=${SSH_AUTH_SOCK:-}
REAL_HOME=$HOME
ROOT=$W/proj
export HOME=$W/home
STATE=$W/state
SESSIONS=$STATE/awl/sessions
VIEW=$SESSIONS/view-42.txt
TMP=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
CACHE=$(cd "$(getconf DARWIN_USER_CACHE_DIR)" && pwd -P)
PIDS=$W/pids       # background jobs the sandboxed commands leave behind
OUTPIDS=$W/outpids # this script's own helpers
: >"$PIDS"
: >"$OUTPIDS"
cleanup() {
  # shellcheck disable=SC2046
  kill $(cat "$PIDS" "$OUTPIDS") $(jobs -p) 2>/dev/null
  launchctl remove "$LABEL.a" 2>/dev/null
  launchctl bootout "gui/$(id -u)/$LABEL.b" 2>/dev/null
  rm -rf "$W" "/private/tmp/awl-probe-$$" "/private/tmp/awl-probe-$$.sock" "$TMP/awl-probe-$$"
}
trap cleanup EXIT

# What commands get as PATH: the system's tools (plus rg's folder), not the caller's wrappers.
SBPATH=/usr/bin:/bin:/usr/sbin:/sbin
command -v rg >/dev/null && SBPATH=$SBPATH:$(dirname "$(command -v rg)")
LABEL=awl.probe.$$ # launchd job names for the launchd probes

pass=0 fail=0 diff=0 skip=0
ok() { echo "ok    $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1: $2"; fail=$((fail + 1)); }
differs() { echo "DIFF  $1: $2"; diff=$((diff + 1)); }
skipped() { echo "skip  $1: $2"; skip=$((skip + 1)); }

# A fake home with secrets, and a git project with instruction files (as tests/sandbox.sh).
mkdir -p "$HOME/.ssh" "$HOME/.docker/run" "$HOME/Library/Application Support/probe" "$HOME/Library/Keychains" \
  "$HOME/Library/LaunchAgents" "$HOME/Library/Caches" "$ROOT/.agents/skills/demo" "$ROOT/sub" "$SESSIONS" \
  "/private/tmp/awl-probe-$$/d/e" "$TMP/awl-probe-$$"
echo SECRETKEY >"$HOME/.ssh/id_probe"
echo SECRETCOOKIE >"$HOME/Library/Application Support/probe/cookie"
echo SECRETKEYCHAIN >"$HOME/Library/Keychains/probe.keychain-db"
echo "export X=1" >"$HOME/.bashrc_probe"
echo '{"content":"OTHERSESSION-hunter3"}' >"$SESSIONS/20200101-000000-1.jsonl"
echo OTHERVIEW-hunter4 >"$SESSIONS/view-1.txt"
echo '{"n":2,"role":"user"}' >"$VIEW"
cd "$ROOT" || exit 1
git init -q
echo "# rules" >AGENTS.md
printf -- '---\nname: demo\ndescription: d\n---\n' >.agents/skills/demo/SKILL.md
cp .git/config "$W/config.before"
printf '#include <stdio.h>\nint main(void){puts("INSIDE-cc");return 0;}\n' >hello.c

# Things outside the sandbox that a command must not reach: a process with a secret in its
# environment, a TCP server on the host's localhost, and Unix sockets in the usual places.
# (python3, not /bin/sleep: the kernel never shows the environment of Apple's own binaries)
PROBE_ENV_SECRET=hunter5 python3 -c 'import time; time.sleep(600)  # awl-probe-outside' &
OUTPID=$!
echo $OUTPID >>"$OUTPIDS"
disown
python3 - "$W" "$HOME/.docker/run/docker.sock" "/private/tmp/awl-probe-$$.sock" "/private/tmp/awl-probe-$$/d/e/f.sock" "$TMP/awl-probe-$$/ipc.sock" <<'EOF' &
import http.server, os, socket, socketserver, sys, threading, time
socks = []
for p in sys.argv[2:]:  # sun_path holds 104 bytes: bind by name from the socket's folder
    os.chdir(os.path.dirname(p))
    s = socket.socket(socket.AF_UNIX); s.bind(os.path.basename(p)); s.listen(); socks.append(s)
os.chdir(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
srv = socketserver.TCPServer(("127.0.0.1", 0), H)  # not HTTPServer: its bind looks up the host's name (slow)
threading.Thread(target=srv.serve_forever, daemon=True).start()
open(sys.argv[1] + "/hostport", "w").write(str(srv.server_address[1]))
time.sleep(600)
EOF
echo $! >>"$OUTPIDS"
disown
for _ in $(seq 100); do [ -s "$W/hostport" ] && break; sleep 0.05; done
HOSTPORT=$(cat "$W/hostport" 2>/dev/null)
[ -n "$HOSTPORT" ] || { echo "the helper outside the sandbox did not start"; exit 1; }
# a port nobody listens on, for the LOCAL=port variant (the block awl would reserve)
OWNPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')

# run [NET=on] [LOCAL=port|host] -- 'command': the command under the profile, in the project,
# with the environment awl would build (an allowlist; sandbox.zig envOk). Prints its output.
run() {
  local net=off loc=off
  while [ "$1" != -- ]; do
    case $1 in NET=*) net=${1#NET=} ;; LOCAL=*) loc=${1#LOCAL=} ;; esac
    shift
  done
  shift
  (cd "$ROOT" && env -i PATH="$SBPATH" HOME="$HOME" TMPDIR="$TMP" LANG=C XDG_STATE_HOME="$STATE" \
    P_W="$W" P_OUTPID="$OUTPID" P_HOSTPORT="$HOSTPORT" P_OWNPORT="$OWNPORT" P_PID="$$" P_TMP="$TMP" \
    P_REALSOCK="$REAL_AUTH_SOCK" P_PIDS="$PIDS" P_LABEL="$LABEL" \
    /usr/bin/sandbox-exec -D ROOT="$ROOT" -D HOME="$HOME" -D TMP="$TMP" -D CACHE="$CACHE" \
    -D SESSIONS="$SESSIONS" -D VIEW="$VIEW" -D NET="$net" -D LOCAL="$loc" -D PORT="$OWNPORT" \
    -f "$HERE/awl.sb" /bin/bash -c "$1; echo RAN" 2>&1)
}
# blocks NAME [variant] -- 'command that prints ESCAPED if it got through'
blocks() {
  local name=$1 out
  shift
  out=$(run "$@")
  if ! grep -q '^RAN$' <<<"$out"; then
    bad "blocks $name" "the probe did not run: $(head -2 <<<"$out")"
  elif grep -q ESCAPED <<<"$out"; then
    bad "blocks $name" "got through$(grep ESCAPED <<<"$out" | head -1 | sed 's/ESCAPED//')"
  else ok "blocks $name"; fi
}
# works NAME [variant] -- 'command that prints INSIDE when it worked'
works() {
  local name=$1 out
  shift
  out=$(run "$@")
  if grep -q INSIDE <<<"$out"; then ok "still works: $name"; else bad "still works: $name" "$(grep -v '^RAN$' <<<"$out" | head -3 | tr '\n' ' ')"; fi
}
CONNECT='python3 -c "import os,socket,sys; os.chdir(os.path.dirname(sys.argv[1])); socket.socket(socket.AF_UNIX).connect(os.path.basename(sys.argv[1]))"'
# every socket the probes aim at answers outside the sandbox (so "blocks" means blocked)
for s in "$HOME/.docker/run/docker.sock" "/private/tmp/awl-probe-$$.sock" "/private/tmp/awl-probe-$$/d/e/f.sock" "$TMP/awl-probe-$$/ipc.sock"; do
  eval "$CONNECT"' "$s"' 2>/dev/null || { echo "control failed: $s does not answer outside the sandbox"; exit 1; }
done
curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$HOSTPORT/" || { echo "control failed: the host server does not answer"; exit 1; }

echo "== network (README: no network unless you say yes) =="
if curl -s --max-time 6 -o /dev/null https://example.com; then HAVE_NET=1; else HAVE_NET=0; fi
blocks net -- 'curl -s --max-time 4 -o /dev/null https://example.com && echo ESCAPED'
blocks "dns (no lookups leave the machine)" -- 'python3 -c "import socket; socket.setdefaulttimeout(4); socket.getaddrinfo(\"example.com\", 443)" 2>/dev/null && echo ESCAPED'
blocks hostlocal -- 'curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$P_HOSTPORT/" && echo ESCAPED'
# (no control: nothing answers at that address on most networks; the rule is the one "net" checks)
blocks metadata -- 'nc -z -G 2 169.254.169.254 80 2>/dev/null && echo ESCAPED'
if [ $HAVE_NET = 1 ]; then
  works "network for one approved command (NET=on)" NET=on -- 'curl -s --max-time 8 -o /dev/null https://example.com && echo INSIDE'
else skipped "network for one approved command" "this machine has no network"; fi
blocks "ssh keys with the network on" NET=on -- 'grep -q SECRETKEY ~/.ssh/id_probe 2>/dev/null && echo ESCAPED'
blocks "docker socket with the network on" NET=on -- "$CONNECT"' "$HOME/.docker/run/docker.sock" 2>/dev/null && echo ESCAPED'
blocks "write outside the project with the network on" NET=on -- 'echo planted 2>/dev/null >>"$HOME/.bashrc_probe" && echo ESCAPED'

echo "== private localhost shared between commands =="
serve='python3 -m http.server $P_OWNPORT --bind 127.0.0.1 >/dev/null 2>&1 & echo $! >>"$P_PIDS"; sleep 1.5; kill -0 $! 2>/dev/null && echo INSIDE-bound'
fetch='for i in 1 2 3 4 5 6 7 8 9 10; do curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$P_OWNPORT/" && echo INSIDE-shared && break; sleep 0.2; done'
out=$(run -- "$serve"; run -- "$fetch")
if grep -q INSIDE-shared <<<"$out"; then
  bad "default: no IP sockets" "a server and a later command talked with LOCAL=off"
else differs "a dev server started in the background is reachable from the next command" "not by default (no IP sockets at all; server bound: $(grep -q INSIDE-bound <<<"$out" && echo yes || echo no))"; fi
# shellcheck disable=SC2046
kill $(cat "$PIDS") 2>/dev/null
: >"$PIDS"
out=$(run LOCAL=port -- "$serve"; run LOCAL=port -- "$fetch")
grep -q INSIDE-shared <<<"$out" && ok "still works: shared localhost on a reserved port (LOCAL=port)" || bad "shared localhost on a reserved port (LOCAL=port)" "$(grep -v RAN <<<"$out" | head -2 | tr '\n' ' ')"
blocks "hostlocal on other ports (LOCAL=port)" LOCAL=port -- 'curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$P_HOSTPORT/" && echo ESCAPED'
blocks "net (LOCAL=port)" LOCAL=port -- 'curl -s --max-time 4 -o /dev/null https://example.com && echo ESCAPED'
out=$(run LOCAL=host -- 'curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$P_HOSTPORT/" && echo ESCAPED')
grep -q ESCAPED <<<"$out" && differs "localhost is private (LOCAL=host)" "cannot be met: with all of localhost allowed, the host's own services are reachable" || ok "blocks hostlocal (LOCAL=host)"
# shellcheck disable=SC2046
kill $(cat "$PIDS") 2>/dev/null
: >"$PIDS"

echo "== sockets and services (README: /run/user, sockets under /tmp, the docker socket) =="
blocks "tmpsock /tmp/S" -- "$CONNECT"' "/private/tmp/awl-probe-$P_PID.sock" 2>/dev/null && echo ESCAPED'
out=$(run -- "$CONNECT"' "/private/tmp/awl-probe-$P_PID/d/e/f.sock" 2>/dev/null && echo ESCAPED')
grep -q ESCAPED <<<"$out" && bad "blocks tmpsock /tmp/D/E/F/S" "got through" || differs "sockets in /tmp reachable three levels deep (embedders rely on it)" "hidden at every depth; AWL_SANDBOX_SOCKETS must name each one"
blocks "tmpsock \$TMPDIR/D/S (editor IPC)" -- "$CONNECT"' "$P_TMP/awl-probe-$P_PID/ipc.sock" 2>/dev/null && echo ESCAPED'
blocks docker -- "$CONNECT"' "$HOME/.docker/run/docker.sock" 2>/dev/null && echo ESCAPED'
if [ -S /var/run/docker.sock ]; then
  blocks "docker (/var/run/docker.sock on this machine)" -- "$CONNECT"' /var/run/docker.sock 2>/dev/null && echo ESCAPED'
else skipped "docker (/var/run/docker.sock)" "none on this machine"; fi
if [ -S "$REAL_AUTH_SOCK" ]; then
  blocks "ssh-agent socket" -- "$CONNECT"' "$P_REALSOCK" 2>/dev/null && echo ESCAPED'
else skipped "ssh-agent socket" "no SSH_AUTH_SOCK here"; fi
works "a Unix socket of its own inside the project" -- 'python3 -c "
import socket
a = socket.socket(socket.AF_UNIX); a.bind(\"own.sock\"); a.listen()
b = socket.socket(socket.AF_UNIX); b.connect(\"own.sock\"); print(\"INSIDE\")"; rm -f own.sock'
# Mach services by name: 0 from bootstrap_look_up means the service is reachable.
LOOKUP='python3 -c "
import ctypes, sys
libc = ctypes.CDLL(None)
bp = ctypes.c_uint.in_dll(libc, \"bootstrap_port\")
port = ctypes.c_uint(0)
sys.exit(0 if libc.bootstrap_look_up(bp, sys.argv[1].encode(), ctypes.byref(port)) == 0 else 1)"'
for svc in "Keychain:com.apple.SecurityServer" "Keychain (xpc):com.apple.securityd.xpc" "pasteboard:com.apple.pasteboard.1" \
  "LaunchServices (open):com.apple.coreservices.launchservicesd" "Apple Events (osascript):com.apple.coreservices.appleevents" \
  "TCC:com.apple.tccd" "window server:com.apple.windowserver.active"; do
  if eval "$LOOKUP"' "${svc#*:}"' 2>/dev/null; then
    blocks "Mach service ${svc%%:*}" -- "$LOOKUP"' '"${svc#*:}"' 2>/dev/null && echo ESCAPED'
  else skipped "Mach service ${svc%%:*}" "${svc#*:} does not answer outside the sandbox either"; fi
done
if [ "$(pbpaste 2>/dev/null | wc -c)" -gt 0 ]; then
  blocks "pbpaste reads the clipboard" -- '[ "$(pbpaste 2>/dev/null | wc -c)" -gt 0 ] && echo ESCAPED'
else skipped "pbpaste reads the clipboard" "the clipboard is empty here"; fi
# launchd is reached over the bootstrap port itself, which no profile can take away: what matters
# is whether a command can start a job (it would run outside the sandbox).
out=$(run -- 'launchctl print "gui/$(id -u)" >/dev/null 2>&1 && echo SEEN')
grep -q SEEN <<<"$out" && differs "launchd is out of reach" "read-only queries answer (launchctl print); starting jobs is checked next" || ok "blocks launchd queries"
cat >"$ROOT/job.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>$LABEL.b</string><key>RunAtLoad</key><true/>
<key>ProgramArguments</key><array><string>/usr/bin/touch</string><string>$W/launchd-b</string></array></dict></plist>
EOF
out=$(run -- 'launchctl submit -l "$P_LABEL.a" -- /usr/bin/touch "$P_W/launchd-a"; echo "submit=$?"; launchctl bootstrap "gui/$(id -u)" job.plist; echo "bootstrap=$?"')
sleep 1.5
if [ -e "$W/launchd-a" ] || [ -e "$W/launchd-b" ]; then
  bad "blocks starting a launchd job (it would run unsandboxed)" "the job ran: $(cd "$W" && echo launchd-*)"
else
  # control: the same plist does start a job from outside the sandbox
  launchctl bootstrap "gui/$(id -u)" "$ROOT/job.plist" 2>/dev/null
  sleep 1.5
  launchctl bootout "gui/$(id -u)/$LABEL.b" 2>/dev/null
  if [ -e "$W/launchd-b" ]; then ok "blocks starting a launchd job (it would run unsandboxed; $(grep -E 'submit=|bootstrap=' <<<"$out" | tr '\n' ' '); the same job starts outside)"
  else skipped "starting a launchd job" "the control job did not start outside the sandbox either"; fi
fi
rm -f "$ROOT/job.plist"

echo "== guarded project paths (.git/config, .git/hooks, AGENTS.md, .agents) =="
blocks gitconfig -- 'git config core.fsmonitor "echo pwned" 2>/dev/null && echo ESCAPED'
blocks githooks -- 'touch .git/hooks/pre-commit 2>/dev/null && echo ESCAPED'
blocks agentsmd -- 'echo x 2>/dev/null >>AGENTS.md && echo ESCAPED'
blocks skills -- 'echo x 2>/dev/null >>.agents/skills/demo/SKILL.md && echo ESCAPED'
works "a tree with its own AGENTS.md can be unpacked (nested ones are not guarded, as on Linux)" -- 'echo x >sub/AGENTS.md && echo INSIDE'
blocks "case: agents.md, .GIT/CONFIG, .git/HOOKS, .Agents" -- 'echo x 2>/dev/null >>agents.md && echo ESCAPED-agents.md; echo x 2>/dev/null >>.GIT/CONFIG && echo ESCAPED-.GIT/CONFIG; touch .git/HOOKS/pre-push 2>/dev/null && echo ESCAPED-HOOKS; touch .Agents/x 2>/dev/null && echo ESCAPED-.Agents'
blocks "rename around the rule (mv .git g; edit; mv g .git)" -- 'mv .git g 2>/dev/null && { echo "[core] fsmonitor = echo pwned" >>g/config; mv g .git; echo ESCAPED; }'
blocks "rename .agents away and back" -- 'mv .agents a2 2>/dev/null && { mv a2 .agents; echo ESCAPED; }'
blocks "move the project to /tmp and back" -- 'cd / && mv "$P_W/proj" "/private/tmp/awl-probe-$P_PID/moved" 2>/dev/null && { mv "/private/tmp/awl-probe-$P_PID/moved" "$P_W/proj"; echo ESCAPED; }'
cmp -s .git/config "$W/config.before" && ok ".git/config unchanged" || bad ".git/config unchanged" "$(tail -2 .git/config | tr '\n' ' ')"
[ "$(cat AGENTS.md)" = "# rules" ] && ok "AGENTS.md unchanged" || bad "AGENTS.md unchanged" "$(cat AGENTS.md)"
added=$(find .git/hooks -type f ! -name '*.sample' | tr '\n' ' ')
[ -z "$added" ] && ok ".git/hooks unchanged" || bad ".git/hooks unchanged" "$added"

echo "== writes (README: only the project, /tmp, build caches) =="
blocks "write to home" -- 'echo planted 2>/dev/null >>"$HOME/.bashrc_probe" && echo ESCAPED; touch "$HOME/new" 2>/dev/null && echo ESCAPED-new'
blocks "LaunchAgents (persistence)" -- 'touch "$HOME/Library/LaunchAgents/x.plist" 2>/dev/null && echo ESCAPED'
blocks "symlink out of the project" -- 'ln -s "$HOME/.bashrc_probe" sl && echo planted 2>/dev/null >>sl && echo ESCAPED; rm -f sl'
blocks "hard link out of the project" -- 'ln "$HOME/.bashrc_probe" hl 2>/dev/null && echo planted 2>/dev/null >>hl && echo ESCAPED; rm -f hl'
blocks "dir symlink + .. (rootlink/..\$HOME/x)" -- 'ln -s / rootlink; echo planted 2>/dev/null >>"rootlink/..$HOME/.bashrc_probe" && echo ESCAPED; rm -f rootlink'
[ "$(cat "$HOME/.bashrc_probe")" = "export X=1" ] && ok "file outside the project unchanged" || bad "file outside the project unchanged" "$(cat "$HOME/.bashrc_probe")"
blocks "session files: write" -- 'for f in "$XDG_STATE_HOME"/awl/sessions/view-*.txt; do echo x 2>/dev/null >>"$f" && echo ESCAPED; done'

echo "== reads (README: hidden paths) =="
blocks sshbash -- 'grep -q SECRETKEY ~/.ssh/id_probe 2>/dev/null && echo ESCAPED'
blocks "case: HOME/.SSH" -- 'grep -q SECRETKEY ~/.SSH/ID_PROBE 2>/dev/null && echo ESCAPED'
blocks "symlink to a secret" -- 'ln -s "$HOME/.ssh/id_probe" sl2; grep -q SECRETKEY sl2 2>/dev/null && echo ESCAPED; rm -f sl2'
blocks "hard link to a secret" -- 'ln "$HOME/.ssh/id_probe" hl2 2>/dev/null; grep -q SECRETKEY hl2 2>/dev/null && echo ESCAPED; rm -f hl2'
blocks "HOME/Library app data (cookies, tokens)" -- 'grep -q SECRETCOOKIE "$HOME/Library/Application Support/probe/cookie" 2>/dev/null && echo ESCAPED'
blocks "HOME/Library/Keychains files" -- 'grep -q SECRETKEYCHAIN "$HOME/Library/Keychains/probe.keychain-db" 2>/dev/null && echo ESCAPED'
blocks sessions -- 'cat "$XDG_STATE_HOME"/awl/sessions/*.jsonl 2>/dev/null | grep -q hunter3 && echo ESCAPED'
blocks otherview -- 'cat "$XDG_STATE_HOME"/awl/sessions/view-1.txt 2>/dev/null | grep -q hunter4 && echo ESCAPED'
works "this session's view" -- 'grep -q "^{\"n\":2,\"role\":\"user\"}" "$XDG_STATE_HOME"/awl/sessions/view-42.txt && echo INSIDE'

echo "== other processes (README: hidden; Linux uses a pid namespace) =="
PROCARGS='python3 -c "
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
mib = (ctypes.c_int * 3)(1, 49, int(sys.argv[1]))  # CTL_KERN, KERN_PROCARGS2: argv and environment
buf = ctypes.create_string_buffer(65536); n = ctypes.c_size_t(65536)
sys.exit(0 if libc.sysctl(mib, 3, buf, ctypes.byref(n), None, 0) == 0 and b\"hunter5\" in buf.raw else 1)"'
eval "$PROCARGS"' $OUTPID' || { echo "control failed: the outside process's environment is not readable outside the sandbox"; exit 1; }
out=$(run -- 'sleep 3 & ps -p $! >/dev/null 2>&1 && echo INSIDE-ps; pgrep -q sleep && echo INSIDE-pgrep; pgrep -f awl-probe-outside | grep -q "^$P_OUTPID\$" && echo SEEN')
grep -q INSIDE-ps <<<"$out" && ok "still works: ps" || differs "ps" "does not run at all: Seatbelt refuses setuid programs (/bin/ps, top); pgrep $(grep -q INSIDE-pgrep <<<"$out" && echo works || echo "does not work either")"
out=$(run -- 'python3 -c "
import ctypes
libc = ctypes.CDLL(None)
mib = (ctypes.c_int * 4)(1, 14, 0, 0)  # kern.proc.all
n = ctypes.c_size_t(0)
print(\"LISTED\" if libc.sysctl(mib, 4, None, ctypes.byref(n), None, 0) == 0 and n.value > 0 else \"none\")"')
grep -q LISTED <<<"$out" && differs "other processes are hidden" "the process table (pids, names) is readable through sysctl; no pid namespace" || ok "blocks listing other processes"
blocks "procenv (another process's environment)" -- "$PROCARGS"' $P_OUTPID 2>/dev/null && echo ESCAPED'
works "a command reads its own child's arguments" -- 'PROBE_ENV_SECRET=hunter5 python3 -c "import time; time.sleep(3)" & sleep 0.7; '"$PROCARGS"' $! && echo INSIDE'
blocks "signal to another process" -- 'kill -0 $P_OUTPID 2>/dev/null && echo ESCAPED'
out=$(run -- 'nohup sleep 300 >/dev/null 2>&1 & echo $! >"$P_W/jobpid"; echo $! >>"$P_PIDS"'; run -- 'kill "$(cat "$P_W/jobpid")" 2>/dev/null && echo INSIDE-killed')
grep -q INSIDE-killed <<<"$out" && ok "still works: a later command stops an earlier command's background job" || differs "a later command stops an earlier command's background job" "refused: each sandbox-exec is its own sandbox, so awl needs one sandboxed holder that starts every command"
out=$(run -- 'sleep 300 & kill $! && echo INSIDE-killed')
grep -q INSIDE-killed <<<"$out" && ok "still works: a command stops its own background job" || bad "a command stops its own background job" "$out"
out=$(run -- '/usr/bin/sandbox-exec -p "(version 1)(allow default)" /usr/bin/true 2>/dev/null && echo NESTED')
grep -q NESTED <<<"$out" && ok "still works: tools that sandbox themselves" || differs "tools that sandbox themselves (swift build, Chromium, bazel, nix)" "fail inside: Seatbelt sandboxes do not nest"

echo "== environment (awl's own allowlist, sandbox.zig envOk: portable code, not Seatbelt) =="
export PROBE_SECRET_TOKEN=hunter2
blocks env -- 'env | grep -q PROBE_SECRET_TOKEN && echo ESCAPED'

echo "== the toolchain still works =="
works "write in the project" -- 'echo made >made.txt && echo INSIDE-$(cat made.txt)'
works "/tmp" -- 'f=/tmp/awl-probe-$P_PID/x; echo t >$f && rm $f && echo INSIDE'
works "\$TMPDIR (mktemp)" -- 'f=$(mktemp) && echo t >"$f" && rm "$f" && echo INSIDE'
works "git add and commit" -- 'git add made.txt && git -c user.name=t -c user.email=t@t commit -qm x && echo INSIDE'
works "git status, log, diff" -- 'git status --short >/dev/null && git log --oneline | grep -q x && echo INSIDE'
if command -v cc >/dev/null; then works "cc builds and runs a program" -- 'cc -o hello hello.c && ./hello'; else skipped "cc" "no compiler"; fi
works "python3" -- 'python3 -c "import tempfile, os; f = tempfile.NamedTemporaryFile(); print(\"INSIDE\", os.getpid())"'
works "ls -l (user names)" -- 'ls -l made.txt | grep -q "$(id -un)" && echo INSIDE'
works "pipes, subshells, here-docs" -- 'cat <<EOF | tr a-z A-Z | grep -q HELLO && echo INSIDE
hello
EOF'
if command -v rg >/dev/null; then works "rg" -- 'rg -n made made.txt >/dev/null && echo INSIDE'; else skipped "rg" "not installed"; fi
if command -v make >/dev/null; then works "make" -- 'printf "all:\n\t@echo INSIDE\n" >Makefile && make'; else skipped "make" "not installed"; fi

echo "== facts the in-process rules (read/write/edit) rest on =="
python3 - "$HOME" "$REAL_HOME" <<'EOF'
import fcntl, os, sys
def getpath(p):
    fd = os.open(p, os.O_RDONLY)
    try: return fcntl.fcntl(fd, 50, bytes(1024)).split(b"\0")[0].decode()  # F_GETPATH
    finally: os.close(fd)
home = sys.argv[1]
a = getpath(home + "/.SSH/ID_PROBE")
print(("ok    " if a == home + "/.ssh/id_probe" else "FAIL  ") + "F_GETPATH returns the on-disk case: .SSH/ID_PROBE -> " + a[len(home):])
b = getpath("/tmp")
print(("ok    " if b == "/private/tmp" else "FAIL  ") + "F_GETPATH resolves /tmp -> " + b)
ci = os.path.exists(home + "/.BASHRC_PROBE")
print("note  this volume is case-%s" % ("insensitive: a new agents.md is AGENTS.md to the next session, so the guard must compare without case" if ci else "sensitive"))
EOF

echo "== cost per command =="
if command -v hyperfine >/dev/null; then
  hyperfine -N -w 10 -r 100 "/usr/bin/true" \
    "/usr/bin/sandbox-exec -D ROOT=$ROOT -D HOME=$HOME -D TMP=$TMP -D CACHE=$CACHE -D SESSIONS=$SESSIONS -D VIEW=$VIEW -D NET=off -D LOCAL=off -D PORT=1 -f $HERE/awl.sb /usr/bin/true" 2>/dev/null |
    grep -E 'Time' | sed -e '1s/^/plain \/usr\/bin\/true: /' -e '2s/^/under awl.sb:       /'
else echo "skip  no hyperfine"; fi

echo "probes: $pass ok, $fail FAIL, $diff DIFF, $skip skipped"
[ $fail -eq 0 ]
