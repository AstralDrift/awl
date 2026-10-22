#!/usr/bin/env python3
"""Drive the awl TUI through a pseudo-terminal against fake_sse.py.
Usage: tui.py path/to/awl"""
import json
import re
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
check("status line", read_until(" step"), buf[-300:])
check("status line: model, time, steps, context", re.search(r"── fake-model · \d+\.\ds · 1 step · ctx 0\.1k · \d+ KB".encode(), buf) is not None, buf[-200:])

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
    # the editor's redraw of the recalled entry (a queued echo would end with "\n", not "\r")
    check("arrow key during a run reaches the prompt", b"wait1" in out and b"upkey-test\r" in out, out[-120:])


keys_during_run()


def safety():
    """ask mode (preview, decline, allow), /undo, plan mode."""
    d = tempfile.mkdtemp()
    g = os.path.join(d, "g.txt")
    open(g, "w").write("one\n")
    turns = [
        {"tool_calls": [{"name": "edit", "arguments": {"path": "g.txt", "old_string": "one", "new_string": "ONE"}}]},
        {"content": "ok declined"},
        {"tool_calls": [{"name": "edit", "arguments": {"path": "g.txt", "old_string": "one", "new_string": "ONE"}}]},
        {"content": "applied"},
        {"content": "noted"},
        {"tool_calls": [{"name": "write", "arguments": {"path": "h.txt", "content": "x"}}]},
        {"content": "planned"},
        {"tool_calls": [{"name": "edit", "arguments": {"path": "g.txt", "old_string": "one", "new_string": "TWO"}}]},
        {"tool_calls": [{"name": "bash", "arguments": {"command": "sleep 1.2"}}]},
        {"tool_calls": [{"name": "write", "arguments": {"path": "k.txt", "content": "k"}}]},
        {"content": "both done"},
    ]
    sp3 = os.path.join(d, "s.json")
    json.dump(turns, open(sp3, "w"))
    log3 = os.path.join(d, "req.jsonl")
    srv3 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp3, "--log", log3], stdout=subprocess.PIPE)
    port3 = srv3.stdout.readline().decode().strip()
    pid3, fd3 = pty.fork()
    if pid3 == 0:
        os.chdir(d)
        os.execve(AWL, [AWL], dict(env, AWL_URL=f"http://127.0.0.1:{port3}"))
    out = [b""]

    def until(pat, t=3.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            r, _, _ = select.select([fd3], [], [], 0.05)
            if r:
                try:
                    out[0] += os.read(fd3, 65536)
                except OSError:
                    break
        return pat.encode() in out[0]

    def reqs():
        return [json.loads(l) for l in open(log3)]
    until("› ")
    os.write(fd3, b"/mode ask\r")
    check("mode set", until("mode: ask"))
    out[0] = b""
    os.write(fd3, b"change it\r")
    check("ask: diff shown before the question", until("allow? y/n") and out[0].find(b"- one") < out[0].find(b"allow?"), out[0][-200:])
    os.write(fd3, b"n")
    check("ask: declined", until("ok declined") and open(g).read() == "one\n", out[0][-200:])
    m = reqs()[-1]["messages"]
    check("ask: model told it was declined", "declined" in m[-1]["content"] and m[-1]["role"] == "tool", m[-1])
    check("mode change told to the model", m[1]["content"].startswith("[Mode is now ask"), m[1]["content"][:60])
    out[0] = b""
    os.write(fd3, b"again\r")
    until("allow? y/n")
    os.write(fd3, b"y")
    check("ask: allowed edit applied", until("applied") and open(g).read() == "ONE\n", out[0][-200:])
    time.sleep(0.3)
    out[0] = b""
    os.write(fd3, b"/undo\r")
    check("/undo restores", until("restored g.txt") and open(g).read() == "one\n", out[0][-200:])
    os.write(fd3, b"thanks\r")
    until("noted")
    last = reqs()[-1]["messages"][-1]["content"]
    check("/undo told to the model", last.startswith("[The user ran /undo.") and last.endswith("thanks"), last[:80])
    time.sleep(0.3)
    os.write(fd3, b"/mode plan\r")
    until("mode: plan")
    os.write(fd3, b"make h\r")
    check("plan: write refused", until("planned") and not os.path.exists(os.path.join(d, "h.txt")), out[0][-200:])
    m = reqs()[-1]["messages"]
    check("plan: model told files are read-only", m[-1]["content"].startswith("Plan mode") and m[-3]["content"].startswith("[Plan mode is on"), [x.get("content", "")[:30] for x in m[-3:]])
    # a message steered in mid-turn joins that turn: one /undo reverts all of it
    time.sleep(0.3)
    os.write(fd3, b"/mode auto\r")
    until("mode: auto")
    os.write(fd3, b"two changes\r")
    until("sleep 1.2")
    os.write(fd3, b"and k too\r")
    check("steered turn finishes", until("both done", 5) and os.path.exists(os.path.join(d, "k.txt")), out[0][-200:])
    time.sleep(0.3)
    out[0] = b""
    os.write(fd3, b"/undo\r")
    check("one /undo reverts the steered turn", until("removed k.txt") and until("restored g.txt") and open(g).read() == "one\n" and not os.path.exists(os.path.join(d, "k.txt")), out[0][-300:])
    os.write(fd3, b"/undo\r")
    check("then nothing is left to undo", until("nothing to undo"), out[0][-200:])
    os.kill(pid3, signal.SIGKILL)
    os.waitpid(pid3, 0)
    srv3.kill()


safety()


def inputs():
    """@file attach + Tab, !cmd, /model, /new + /resume, history across restarts + Ctrl-R."""
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "src"))
    open(os.path.join(d, "src", "parser.py"), "w").write("def parse(s):\n    return s.split()\n")
    open(os.path.join(d, "src", "pager.py"), "w").write("x\n")
    sp4 = os.path.join(d, "s.json")
    json.dump([{"content": "seen"}] * 4 + [{"delay": 1, "content": "slow-seen"}, {"content": "seen"}], open(sp4, "w"))
    log4 = os.path.join(d, "req.jsonl")
    srv4 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp4, "--log", log4], stdout=subprocess.PIPE)
    port4 = srv4.stdout.readline().decode().strip()
    env4 = dict(env, AWL_URL=f"http://127.0.0.1:{port4}", XDG_STATE_HOME=os.path.join(d, "state"))
    out = [b""]

    def start():
        p, f = pty.fork()
        if p == 0:
            os.chdir(d)
            os.execve(AWL, [AWL], env4)
        return p, f

    def until(f, pat, t=3.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            r, _, _ = select.select([f], [], [], 0.05)
            if r:
                try:
                    out[0] += os.read(f, 65536)
                except OSError:
                    break
        return pat.encode() in out[0]

    def reqs():
        return [json.loads(l) for l in open(log4)]
    p4, f4 = start()
    until(f4, "› ")
    os.write(f4, b"read @src/par\t")
    check("tab completes a unique @file", until(f4, "@src/parser.py "), out[0][-120:])
    os.write(f4, b"\r")
    until(f4, " step")
    time.sleep(0.3)
    c = reqs()[-1]["messages"][-1]["content"]
    check("@file attached to the message", c.startswith("read @src/parser.py") and '<file path="src/parser.py">\ndef parse(s):\n    return s.split()\n</file>' in c, c[:120])
    out[0] = b""
    os.write(f4, b"@src/pa\t")
    check("tab opens the file picker on several choices", until(f4, "attach a file") and until(f4, "src/parser.py") and b"src/pager.py" in out[0], out[0][-300:])
    out[0] = b""
    os.write(f4, b"\x1b[B\r")  # second entry
    check("picked file replaces the word", until(f4, "@src/parser.py "), out[0][-200:])
    out[0] = b""
    os.write(f4, b"\x15/und\t")
    check("tab completes a unique /command", until(f4, "/undo"), out[0][-120:])
    out[0] = b""
    os.write(f4, b"\x15/co\t")
    check("tab on /co opens the command picker", until(f4, "commands") and until(f4, "/compact"), out[0][-300:])
    os.write(f4, b"\x1b")
    time.sleep(0.2)
    os.write(f4, b"\x15!echo hi-from-shell\r")
    check("!cmd output shown", until(f4, "hi-from-shell\r\n"), out[0][-120:])
    os.write(f4, b"/model other-model\r")
    check("/model switches", until(f4, "model: other-model"), out[0][-120:])
    out[0] = b""
    os.write(f4, b"next\r")
    until(f4, "seen")
    r = reqs()[-1]
    check("!cmd output goes to the model", r["messages"][-1]["content"] == "[The user ran `echo hi-from-shell` in the shell:\nhi-from-shell\n]\n\nnext", r["messages"][-1]["content"][:100])
    check("next request uses the new model", r["model"] == "other-model", r["model"])
    time.sleep(0.3)
    os.write(f4, b"/new\r")
    until(f4, "new conversation")
    time.sleep(1.1)  # session files are named by the second
    out[0] = b""
    os.write(f4, b"second chat\r")
    until(f4, " step")
    time.sleep(0.3)
    out[0] = b""
    os.write(f4, b"/resume 99\r")
    check("/resume with a bad number keeps awl running", until(f4, "no session 99") and until(f4, "› "), out[0][-200:])
    out[0] = b""
    os.write(f4, b"/resume\r")
    check("/resume opens a picker of this folder's sessions", until(f4, "resume a conversation") and until(f4, "read @src/parser.py") and b"second chat  (this one)" in out[0], out[0][-300:])
    os.write(f4, b"\x1b[B\r")
    check("picking a session resumes it", until(f4, "resumed 4 messages"), out[0][-200:])
    out[0] = b""
    os.write(f4, b"after resume\r")
    until(f4, " step")
    m = reqs()[-1]["messages"]
    check("resumed conversation continues", m[1]["content"].startswith("read @src/parser.py") and m[-1]["content"] == "after resume", [x["content"][:20] for x in m[1:]])
    # a /command typed while the model works runs after the turn instead of being sent
    time.sleep(0.3)
    n_before = len(reqs())
    out[0] = b""
    os.write(f4, b"slow one\r")
    time.sleep(0.4)
    os.write(f4, b"/context\r")
    check("held /command shown while waiting", until(f4, "then /context"), out[0][-200:])
    check("held /command runs after the turn", until(f4, "slow-seen") and until(f4, "context: ") and len(reqs()) == n_before + 1, out[0][-200:])
    os.kill(p4, signal.SIGKILL)
    os.waitpid(p4, 0)
    out[0] = b""
    p4, f4 = start()
    until(f4, "› ")
    os.write(f4, b"parser\x12")
    check("history survives a restart (Ctrl-R)", until(f4, "read @src/parser.py"), out[0][-200:])
    os.kill(p4, signal.SIGKILL)
    os.waitpid(p4, 0)
    srv4.kill()


inputs()


def screens():
    """Welcome screen, status line under the prompt, Omarchy theme reloaded live."""
    d = tempfile.mkdtemp()
    proj = os.path.join(d, "proj")
    os.makedirs(os.path.join(proj, ".git"))
    open(os.path.join(proj, ".git", "HEAD"), "w").write("ref: refs/heads/feat-x\n")
    open(os.path.join(proj, "AGENTS.md"), "w").write("- be brief\n")
    theme = os.path.join(d, "home", ".local", "state", "omarchy", "current", "theme")
    os.makedirs(theme)
    colors = os.path.join(theme, "colors.toml")
    open(colors, "w").write('accent = "#112233"\n')
    sp5 = os.path.join(d, "s.json")
    json.dump([{"content": "hi"}], open(sp5, "w"))
    srv5 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp5, "--ctx", "32000", "--models", "big-model,small-model"], stdout=subprocess.PIPE)
    port5 = srv5.stdout.readline().decode().strip()
    env5 = dict(env, AWL_URL=f"http://127.0.0.1:{port5}", XDG_STATE_HOME=os.path.join(d, "state"), HOME=os.path.join(d, "home"))
    out = [b""]

    def start(extra={}):
        p, f = pty.fork()
        if p == 0:
            os.chdir(proj)
            os.execve(AWL, [AWL], dict(env5, **extra))
        fcntl.ioctl(f, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        return p, f

    def until(f, pat, t=3.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            r, _, _ = select.select([f], [], [], 0.05)
            if r:
                try:
                    out[0] += os.read(f, 65536)
                except OSError:
                    break
        return pat.encode() in out[0]

    p5, f5 = start()
    until(f5, "› ")
    until(f5, "auto", 1)
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0])
    check("welcome: model, window, mode", b"awl 0.1.0 \xc2\xb7 fake-model \xc2\xb7 32k context \xc2\xb7 mode auto" in plain, plain[:300])
    check("welcome: branch and AGENTS.md", b"\xe2\x8e\x87 feat-x \xc2\xb7 1 AGENTS.md" in plain, plain[:300])
    check("status line under the prompt", b"fake-model \xc2\xb7 ctx 0% of 32k \xc2\xb7 auto \xc2\xb7 \xe2\x8e\x87 feat-x" in plain, plain[-200:])
    check("theme accent on the prompt", b"\x1b[38;2;17;34;51m\xe2\x80\xba " in out[0], out[0][-200:])
    time.sleep(0.05)
    open(colors, "w").write('accent = "#445566"\n')
    out[0] = b""
    os.write(f5, b"\r")  # an empty line: a fresh prompt picks up the new theme
    check("theme change applies at the next prompt", until(f5, "\x1b[38;2;68;85;102m"), out[0][-200:])
    out[0] = b""
    os.write(f5, b"hello\r")
    check("status line gone from the sent prompt", until(f5, " step") and b"of 32k \xc2\xb7 auto" not in out[0].split(b"hello")[1].split(b"hi")[0], out[0][:300])
    out[0] = b""
    os.write(f5, b"/model\r")
    check("/model opens the model picker", until(f5, "switch model") and until(f5, "small-model  64k"), out[0][-300:])
    out[0] = b""
    os.write(f5, b"\x1b[B\r")
    check("picked model is used, window from the list", until(f5, "model: big-model") and until(f5, "of 64k"), out[0][-300:])
    os.kill(p5, signal.SIGKILL)
    os.waitpid(p5, 0)
    out[0] = b""
    p5, f5 = start({"AWL_STATUS": "off", "AWL_WELCOME": "off", "AWL_MODELS": "fake-model,small-model"})
    until(f5, "› ")
    time.sleep(0.3)
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0])
    check("AWL_WELCOME=off: one line, AWL_STATUS=off: no status line", plain.count(b"fake-model") == 1 and b"Enter send" not in plain and b"auto" not in plain, plain)
    out[0] = b""
    os.write(f5, b"\x10")
    check("Ctrl-P switches to the next model in AWL_MODELS", until(f5, "model: small-model"), out[0][-200:])
    os.kill(p5, signal.SIGKILL)
    os.waitpid(p5, 0)
    out[0] = b""
    p5, f5 = start()
    until(f5, "› ")
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0])
    check("welcome offers the last session here", b"last here just now: \xe2\x80\x9chello\xe2\x80\x9d \xc2\xb7 /resume 1" in plain, plain[:400])
    os.kill(p5, signal.SIGKILL)
    os.waitpid(p5, 0)
    srv5.kill()


screens()


def todo_panel():
    """The model's checklist stays pinned above the live line while a tool runs."""
    d = tempfile.mkdtemp()
    items = lambda st: [{"text": "read the parser", "status": st[0]}, {"text": "fix tokenize", "status": st[1]}, {"text": "add a test", "status": st[2]}]
    turns = [
        {"tool_calls": [{"name": "todo", "arguments": {"items": items(["done", "doing", "pending"])}}]},
        {"tool_calls": [{"name": "bash", "arguments": {"command": "sleep 2"}}]},
        {"tool_calls": [{"name": "todo", "arguments": {"items": items(["done", "done", "done"])}}]},
        {"content": "panel done"},
    ]
    sp6 = os.path.join(d, "s.json")
    json.dump(turns, open(sp6, "w"))
    srv6 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp6], stdout=subprocess.PIPE)
    port6 = srv6.stdout.readline().decode().strip()
    p6, f6 = pty.fork()
    if p6 == 0:
        os.chdir(d)
        os.execve(AWL, [AWL], dict(env, AWL_URL=f"http://127.0.0.1:{port6}", XDG_STATE_HOME=os.path.join(d, "state")))
    fcntl.ioctl(f6, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = b""
    end = time.time() + 1
    while time.time() < end:
        if select.select([f6], [], [], 0.05)[0]:
            out += os.read(f6, 65536)
    os.write(f6, b"go\r")
    out = b""
    end = time.time() + 4
    while b"panel done" not in out and time.time() < end:
        if select.select([f6], [], [], 0.05)[0]:
            out += os.read(f6, 65536)
    during = out.split(b"sleep 2")[1].split(b"(no output)")[0] if b"(no output)" in out else out
    check("todo output drawn as a checklist", "  ✓ read the parser".encode() in re.sub(rb"\x1b\[[0-9;]*m", b"", out), out[:300])
    check("checklist pinned while a tool runs", b"1 done" in during and "▸ fix tokenize".encode() in re.sub(rb"\x1b\[[0-9;]*m", b"", during) and b"\xe2\x8b\xaf 1s" in during, during[-300:])
    check("pinned checklist cleared before output", b"\x1b[3A\r\x1b[J" in out and b"panel done" in out, out[-300:])
    os.kill(p6, signal.SIGKILL)
    os.waitpid(p6, 0)
    srv6.kill()


todo_panel()


def full_screen():
    """--full: alternate screen, conversation drawn above the input, PgUp scrolls,
    the transcript is printed on the normal screen at exit; /full toggles."""
    d = tempfile.mkdtemp()
    long = "\n".join(f"row {i}" for i in range(1, 61))
    turns = [{"content": "short reply"}, {"content": long}, {"content": "after toggle"}]
    sp7 = os.path.join(d, "s.json")
    json.dump(turns, open(sp7, "w"))
    srv7 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp7], stdout=subprocess.PIPE)
    port7 = srv7.stdout.readline().decode().strip()
    p7, f7 = pty.fork()
    if p7 == 0:
        os.chdir(d)
        os.execve(AWL, [AWL, "--full"], dict(env, AWL_URL=f"http://127.0.0.1:{port7}", XDG_STATE_HOME=os.path.join(d, "state")))
    fcntl.ioctl(f7, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = [b""]

    def until(pat, t=3.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            if select.select([f7], [], [], 0.05)[0]:
                try:
                    out[0] += os.read(f7, 65536)
                except OSError:
                    break
        return pat.encode() in out[0]

    check("--full enters the alternate screen with wheel reports", until("\x1b[?1049h\x1b[?1000h\x1b[?1006h"), out[0][:120])
    until("fake-model \xc2\xb7 ".encode().decode("latin-1"), 1)
    until("\x1b[?2026l")
    check("--full: status line on the last row", re.search(rb"\x1b\[24;1H\x1b\[0m\x1b\[[0-9;]*mfake-model", out[0]) is not None, out[0][-300:])
    out[0] = b""
    os.write(f7, b"hi\r")
    check("--full: reply drawn in the view", until("short reply") and until(" step"), out[0][-300:])
    out[0] = b""
    os.write(f7, b"long one\r")
    until(" step")
    time.sleep(0.3)
    out[0] = b""
    os.write(f7, b"\x1b[5~")
    check("PgUp scrolls the view up", until("rows \xc2\xb7 PgDn".encode().decode("latin-1")) or until("rows · PgDn"), out[0][-300:])
    out[0] = b""
    os.write(f7, b"\x1b[5~" * 12)  # far past the top
    until("no such text", 0.6)  # read the frames
    frame = out[0].split(b"\x1b[?2026h")[-1]
    check("PgUp past the top shows the first page, not a blank view", b"0.1.0" in frame and b"row 1\x1b" in frame, frame[-300:])
    out[0] = b""
    os.write(f7, b"\x1b[<65;10;5M" * 30)  # wheel down to the bottom
    time.sleep(0.4)
    check("wheel down returns to the bottom", until("row 60") and b"PgDn" not in out[0].split(b"row 60")[-1], out[0][-200:])
    out[0] = b""
    os.write(f7, b"/full\r")
    check("/full leaves: transcript printed on the normal screen", until("\x1b[?1049l") and until("row 60") and b"short reply" in out[0], out[0][-200:])
    out[0] = b""
    os.write(f7, b"/full\r")
    check("/full enters again", until("\x1b[?1049h"), out[0][-100:])
    os.write(f7, b"x\r")
    until("after toggle")
    out[0] = b""
    os.write(f7, b"\x04")  # Ctrl-D quits
    check("quitting prints the transcript and restores the screen", until("\x1b[?1049l") and until("after toggle"), out[0][-200:])
    try:
        os.waitpid(p7, 0)
    except ChildProcessError:
        pass
    srv7.kill()


full_screen()
print(f"tui: {'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
