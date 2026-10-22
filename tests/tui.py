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
    {"tool_calls": [{"name": "bash", "arguments": {"command": "sleep 1.5"}}]},
    {"content": "steered ok"},
    {"tool_calls": [{"name": "edit", "arguments": {"path": "f.txt", "old_string": "beta", "new_string": "BETA"}}]},
    {"content": "**done** edit"},
    {"delay": 5, "content": "slow2"},
    {"content": "final"},
    {"content": "pasted ok"},
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

import fcntl, struct
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
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

# type-ahead: a message typed while a tool runs reaches the model at the next step
buf = b""
send("steer test\r")
read_until("sleep 1.5", 3)
time.sleep(1.2)
send("also check docs\r")
check("steered reply", read_until("steered ok", 5), buf[-300:])
m = requests()[-1]["messages"]
check("queued message sent after the tool result", m[-1] == {"role": "user", "content": "also check docs"} and m[-2]["role"] == "tool", [x["role"] for x in m[-3:]])
check("live line with timer", "⋯ 1s".encode() in buf, buf[-400:])
check("queued count shown", b"1 queued" in buf, buf[-400:])
check("queued message echoed", "› \x1b[0malso check docs".encode() in buf or b"also check docs\n" in buf.replace(b"\r", b""), buf[-400:])

# edit shows a diff; **bold** renders as bold
open(os.path.join(W, "f.txt"), "w").write("alpha\nbeta\ngamma\n")
buf = b""
send("edit it\r")
check("edit reply", read_until("edit", 5) and read_until("\x1b[1mdone\x1b[22m", 5), buf[-300:])
check("diff lines", b"- beta" in buf and b"+ BETA" in buf, buf[-400:])
check("edit applied", open(os.path.join(W, "f.txt")).read() == "alpha\nBETA\ngamma\n")

# Esc interrupts; text typed but not sent comes back in the prompt
send("slow again\r")
time.sleep(0.5)
send("half typed")
time.sleep(0.3)
buf = b""
t0 = time.time()
send("\x1b")
got = read_until("interrupted", 2)
dt = (time.time() - t0) * 1000
check(f"esc interrupts ({dt:.0f} ms)", got and dt < 700, buf[-200:])
check("draft back in the prompt", read_until("half typed", 2), buf[-200:])
send("\x15")  # Ctrl-U
send("x\r")
check("continues after esc", read_until("final", 3), buf[-300:])

# a paste taller than the screen (24 rows here): windowed while typing, sent and shown once
rows = "".join(f"row-{i:03d}\n" for i in range(60))
send("\x1b[200~" + rows.replace("\n", "\r") + "\x1b[201~tail")
check("tall input is windowed", read_until("more lines · Ctrl-O shows all", 2), buf[-300:])
read_until("tail", 1)
time.sleep(0.3)
read_until("never", 0.3)  # drain the last redraw
buf = b""
send("\r")
check("tall paste reply", read_until("pasted ok", 3), buf[-200:])
check("tall paste printed once on send", buf.count(b"row-") == 60, buf.count(b"row-"))
got = requests()[-1]["messages"][-1]["content"]
check("tall paste sent whole", got == rows + "tail", repr(got[:80]) + " ... " + repr(got[-40:]))

# /copy sends the last reply to the terminal clipboard (OSC 52); Ctrl-O at an empty
# prompt prints the last tool output in full
import base64
buf = b""
send("/copy\r")
check("/copy emits OSC 52", read_until("copied 1 lines", 2) and b"\x1b]52;c;" + base64.b64encode(b"pasted ok") + b"\x07" in buf, buf[-200:])
buf = b""
send("\x0f")
check("ctrl-o shows the last tool output", read_until("+ BETA", 2) or read_until("edited", 2), buf[-200:])

# double Ctrl-C at an empty prompt quits and restores the terminal
send("\x03")
read_until("again to quit", 2)
send("\x03")
status = None
for _ in range(100):
    p, st = os.waitpid(pid, os.WNOHANG)
    if p:
        status = st
        break
    time.sleep(0.05)
if status is None:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
check("double ctrl-c exits 0", status is not None and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0, status)
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


def keys_during_run():
    """Fresh session: Up pressed while a reply is still coming recalls history afterwards."""
    sp2 = os.path.join(W, "s2.json")
    json.dump([{"content": "first"}, {"delay": 1, "content": "wait1"}], open(sp2, "w"))
    srv2 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp2], stdout=subprocess.PIPE)
    port2 = srv2.stdout.readline().decode().strip()
    pid2, fd2 = pty.fork()
    if pid2 == 0:
        os.chdir(W)
        os.execve(AWL, [AWL], dict(env, AWL_URL=f"http://127.0.0.1:{port2}"))

    def drain(t):
        out = b""
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd2], [], [], 0.05)
            if r:
                try:
                    out += os.read(fd2, 65536)
                except OSError:
                    break
        return out
    drain(0.5)
    os.write(fd2, b"hello\r")
    drain(0.8)
    os.write(fd2, b"upkey-test\r")
    drain(0.4)
    os.write(fd2, b"\x1b[A")
    out = drain(1.5)
    os.kill(pid2, signal.SIGKILL)
    os.waitpid(pid2, 0)
    srv2.kill()
    # the editor's redraw of the recalled entry (a queued echo would end with "\n")
    check("arrow key during a run reaches the prompt", b"wait1" in out and b"upkey-test\r\x1b[" in out, out[-120:])


keys_during_run()
print(f"tui: {'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
