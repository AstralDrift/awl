#!/usr/bin/env python3
"""Drive the awl TUI through a pseudo-terminal against fake_sse.py.
Usage: tui.py path/to/awl"""
import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time

AWL = os.path.abspath(sys.argv[1])
HERE = os.path.dirname(os.path.abspath(__file__))
W = tempfile.mkdtemp()
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f": {detail}"))
    fails += 0 if cond else 1


script = [
    {"content": "first answer"},
    {"content": "second answer"},
    {"content": "multi ok"},
    {"delay": 5, "content": "too late"},
    {"tool_calls": [{"name": "bash", "arguments": {"command": "sleep 100"}}]},
    {"content": "after cancel"},
]
sp = os.path.join(W, "s.json")
json.dump(script, open(sp, "w"))
log = os.path.join(W, "req.jsonl")
subprocess.run(["pkill", "-x", "-f", "sleep 100"])
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp, "--log", log], stdout=subprocess.PIPE)
port = srv.stdout.readline().decode().strip()

env = dict(os.environ, AWL_URL=f"http://127.0.0.1:{port}", XDG_STATE_HOME=os.path.join(W, "state"), TERM="xterm-256color")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(W)
    os.execve(AWL, [AWL], env)

buf = b""


def read_until(pat, timeout=5.0):
    global buf
    end = time.time() + timeout
    while pat.encode() not in buf:
        left = end - time.time()
        if left <= 0:
            return False
        r, _, _ = select.select([fd], [], [], left)
        if r:
            try:
                buf += os.read(fd, 65536)
            except OSError:
                return False
    return True


def send(s):
    os.write(fd, s.encode() if isinstance(s, str) else s)


def requests():
    return [json.loads(l) for l in open(log)] if os.path.exists(log) else []


check("banner + prompt", read_until("› "), buf[-200:])
try:
    toml = open(os.path.expanduser("~/.local/state/omarchy/current/theme/colors.toml")).read()
    acc = [l.split("=")[1].strip().strip('"#') for l in toml.splitlines() if l.startswith("accent")][0]
    sgr = "\x1b[38;2;%d;%d;%dm" % (int(acc[0:2], 16), int(acc[2:4], 16), int(acc[4:6], 16))
    check("omarchy accent color on prompt", (sgr + "› ").encode() in buf, buf[:200])
except (OSError, IndexError):
    print("skip theme check (no omarchy colors.toml)")
send("hello\r")
check("first reply", read_until("first answer"), buf[-300:])
check("status line", read_until("tok/s"), buf[-300:])

send("again\r")
check("second reply", read_until("second answer"), buf[-300:])

# multi-line via Alt-Enter and Ctrl-J, then bracketed paste with a newline
buf = b""
send("line1\x1b\rline2\nline3 ")
send("\x1b[200~pasted\rtext\x1b[201~\r")
check("multi-line reply", read_until("multi ok"), buf[-300:])
last_user = requests()[-1]["messages"][-1]["content"]
check("multi-line content", last_user == "line1\nline2\nline3 pasted\ntext", repr(last_user))

# history: Up twice recalls "again"
buf = b""
send("\x1b[A\x1b[A")
time.sleep(0.2)
check("history recall", read_until("again", 2), buf[-200:])
send("\x15")  # Ctrl-U clears the recalled line

# Ctrl-C while waiting for a slow model
send("slow\r")
time.sleep(0.5)
buf = b""
t0 = time.time()
send("\x03")
got = read_until("interrupted", 2)
dt = (time.time() - t0) * 1000
check(f"ctrl-c during stream ({dt:.0f} ms)", got and dt < 100, buf[-200:])
check("prompt back", read_until("› ", 2), buf[-200:])

# Ctrl-C while a tool runs
send("run it\r")
read_until("sleep 100", 3)
time.sleep(0.3)
buf = b""
t0 = time.time()
send("\x03")
got = read_until("interrupted", 2)
dt = (time.time() - t0) * 1000
check(f"ctrl-c during tool ({dt:.0f} ms)", got and dt < 100, buf[-200:])
time.sleep(0.2)
check("tool group killed", subprocess.run(["pgrep", "-f", "sleep 100"], capture_output=True).returncode != 0)
m = requests()[-1]["messages"] if requests() else []
send("next\r")
check("loop continues after cancel", read_until("after cancel", 3), buf[-300:])
m = requests()[-1]["messages"]
roles = [x["role"] for x in m]
check("cancelled tool has a result", "tool" in roles and any("interrupted" in (x.get("content") or "") for x in m if x["role"] == "tool"), roles)

# double Ctrl-C at an empty prompt quits and restores the terminal
send("\x03")
read_until("again to quit", 2)
send("\x03")
try:
    _, status = os.waitpid(pid, 0)
    check("double ctrl-c exits 0", os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, status)
except ChildProcessError:
    check("double ctrl-c exits", False)
while True:
    try:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            break
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        buf += chunk
    except OSError:
        break
check("bracketed paste disabled on exit", buf.rstrip().endswith(b"\x1b[?2004l\x1b[0m") or b"\x1b[?2004l" in buf[-40:], buf[-60:])

srv.kill()
print(f"tui: {'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
