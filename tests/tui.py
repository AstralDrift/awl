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
    {"content": "big paste ok"},
    {"delay": 3, "content": "busy slow"},
    {"content": "busy paste ok"},
]
sp = os.path.join(W, "s.json")
json.dump(script, open(sp, "w"))
log = os.path.join(W, "req.jsonl")
subprocess.run(["pkill", "-x", "-f", "sleep 100"])
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp, "--log", log], stdout=subprocess.PIPE)
port = srv.stdout.readline().decode().strip()

# These checks read colors. `zig build` sets NO_COLOR when its own output is not a terminal.
env = {k: v for k, v in os.environ.items() if k != "NO_COLOR"}
env.update(AWL_URL=f"http://127.0.0.1:{port}", XDG_STATE_HOME=os.path.join(W, "state"), TERM="xterm-256color")
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


def send_drain(s):
    """Write a large payload while reading awl's output, as a terminal does (a plain write deadlocks on a full pty)."""
    global buf
    d = s.encode() if isinstance(s, str) else s
    i = 0
    while i < len(d):
        r, w, _ = select.select([fd], [fd], [], 5)
        if r:
            try:
                buf += os.read(fd, 1 << 20)
            except OSError:
                return
        if w:
            i += os.write(fd, d[i:i + 4096])


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

# pastes beyond the old fixed buffers: idle (was cut to 64 KiB) and while a turn runs (was cut to 8 KiB, dropped past 16 KiB)
bigtxt = ("0123456789abcdef" * 8 + "\n") * 2400  # 309,600 chars
buf = b""
send_drain("\x1b[200~" + bigtxt.replace("\n", "\r") + "\x1b[201~end")
read_until("never", 0.5)
send("\r")
check("300 KB paste reply", read_until("big paste ok", 15), buf[-200:])
got = requests()[-1]["messages"][-1]["content"]
check("300 KB paste sent whole", got == bigtxt + "end", f"sent {len(bigtxt) + 3} chars, got {len(got)}")
buf = b""
send("busyslow\r")
time.sleep(0.8)
steer = "".join(f"steer-{i:04d} " + "x" * 40 + "\n" for i in range(400))  # ~21 KB
send_drain("\x1b[200~" + steer.replace("\n", "\r") + "\x1b[201~\r")
check("busy 21 KB paste delivered after the turn", read_until("busy paste ok", 15), buf[-300:])
got = requests()[-1]["messages"][-1]["content"]
check("busy 21 KB paste sent whole", got.strip() == steer.strip(), f"sent {len(steer.strip())} chars, got {len(got.strip())}")

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


def lockdown():
    """Auto mode still asks before a command uses the network and before AGENTS.md changes; y/n only."""
    d = tempfile.mkdtemp()
    agents = os.path.join(d, "AGENTS.md")
    open(agents, "w").write("# rules\n")
    pf = os.path.join(d, "port")
    probe = 'curl -s -o /dev/null -w REACHED-%{http_code} "http://127.0.0.1:$(cat ' + pf + ')/v1/models"'
    turns = [
        {"tool_calls": [{"name": "bash", "arguments": {"command": probe, "network": True}}]},
        {"content": "net declined"},
        {"tool_calls": [{"name": "bash", "arguments": {"command": probe, "network": True}}]},
        {"content": "net used"},
        {"tool_calls": [{"name": "bash", "arguments": {"command": probe}}]},
        {"content": "no net"},
        {"tool_calls": [{"name": "write", "arguments": {"path": "AGENTS.md", "content": "planted\n"}}]},
        {"content": "agents declined"},
        {"tool_calls": [{"name": "write", "arguments": {"path": "AGENTS.md", "content": "# rules v2\n"}}]},
        {"content": "agents written"},
    ]
    sp8 = os.path.join(d, "s.json")
    json.dump(turns, open(sp8, "w"))
    log8 = os.path.join(d, "req.jsonl")
    srv8 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp8, "--log", log8], stdout=subprocess.PIPE)
    port8 = srv8.stdout.readline().decode().strip()
    open(pf, "w").write(port8)
    p8, f8 = pty.fork()
    if p8 == 0:
        os.chdir(d)
        os.execve(AWL, [AWL], dict(env, AWL_URL=f"http://127.0.0.1:{port8}", AWL_MODE="auto"))
    out = [b""]

    def until(pat, t=5.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            r, _, _ = select.select([f8], [], [], 0.05)
            if r:
                try:
                    out[0] += os.read(f8, 65536)
                except OSError:
                    break
        return pat.encode() in out[0]

    def last_tool():
        m = [json.loads(l) for l in open(log8)][-1]["messages"]
        return [x for x in m if x["role"] == "tool"][-1]["content"]
    until("› ")
    os.write(f8, b"fetch\r")
    asked = until("allow? y/n")
    check("network: asked in auto mode, y/n only", asked and b"a = all" not in out[0].split(b"wants the network")[-1], out[0][-200:])
    os.write(f8, b"n")
    check("network: declined, nothing reached", until("net declined") and "REACHED" not in last_tool(), last_tool()[:200])
    time.sleep(0.3)
    out[0] = b""
    os.write(f8, b"again\r")
    until("allow? y/n")
    os.write(f8, b"y")
    until("net used")
    t = last_tool()
    check("network: approved command reaches the host", re.search(r"REACHED-[1-5]", t) is not None and "approved by the user for this command only" in t, t[:200])
    time.sleep(0.3)
    out[0] = b""
    os.write(f8, b"without\r")
    until("no net")
    t = last_tool()
    check("network: without the flag nothing reaches the host", "REACHED-000" in t and b"allow?" not in out[0], t[:200])
    time.sleep(0.3)
    out[0] = b""
    os.write(f8, b"plant\r")
    check("AGENTS.md: asked in auto mode", until("allow? y/n"), out[0][-200:])
    os.write(f8, b"a")  # "all" is not an answer here
    time.sleep(0.3)
    os.write(f8, b"n")
    check("AGENTS.md: declined, unchanged", until("agents declined") and open(agents).read() == "# rules\n", open(agents).read())
    time.sleep(0.3)
    out[0] = b""
    os.write(f8, b"update\r")
    until("allow? y/n")
    os.write(f8, b"y")
    check("AGENTS.md: allowed, written", until("agents written") and open(agents).read() == "# rules v2\n", open(agents).read() + " | " + last_tool()[:200])
    os.kill(p8, signal.SIGKILL)
    os.waitpid(p8, 0)
    srv8.kill()


lockdown()


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
    until(f5, "of 32k · auto", 2)  # the footer is drawn after the prompt; "auto" alone matches the welcome line
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


def todo_hidden():
    """Ctrl-T while it works folds the pinned checklist into a count on the timer line; at the prompt it shows the list."""
    d = tempfile.mkdtemp()
    items = lambda st: [{"text": "read the parser", "status": st[0]}, {"text": "fix tokenize", "status": st[1]}, {"text": "add a test", "status": st[2]}]
    turns = [
        {"tool_calls": [{"name": "todo", "arguments": {"items": items(["done", "doing", "pending"])}}]},
        {"tool_calls": [{"name": "bash", "arguments": {"command": "sleep 2.5"}}]},
        {"tool_calls": [{"name": "todo", "arguments": {"items": items(["done", "done", "doing"])}}]},
        {"content": "hidden done"},
    ]
    spx = os.path.join(d, "s.json")
    json.dump(turns, open(spx, "w"))
    srvx = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), spx], stdout=subprocess.PIPE)
    portx = srvx.stdout.readline().decode().strip()
    px, fx = pty.fork()
    if px == 0:
        os.chdir(d)
        os.execve(AWL, [AWL], dict(env, AWL_URL=f"http://127.0.0.1:{portx}", XDG_STATE_HOME=os.path.join(d, "state")))
    fcntl.ioctl(fx, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = [b""]

    def until(pat, t=4.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            if select.select([fx], [], [], 0.05)[0]:
                out[0] += os.read(fx, 65536)
        return pat.encode() in out[0]

    until("› ")
    os.write(fx, b"go\r")
    until("sleep 2.5")
    out[0] = b""
    os.write(fx, b"\x14")  # Ctrl-T
    seen = until("☰ 1/3", 2.0)
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0])
    check("Ctrl-T while working: count on the timer line, no pinned rows", seen and "▸ fix tokenize".encode() not in plain, plain[-300:])
    out[0] = b""
    until("hidden done")
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0])
    check("hidden: a todo call prints one line, not the list", "☰ tasks 2/3 done · Ctrl-T shows them".encode() in plain and "▸ add a test".encode() not in plain, plain[-400:])
    until("› ")
    out[0] = b""
    os.write(fx, b"\x14")
    plain_ok = until("add a test")
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0])
    check("Ctrl-T at the prompt shows the checklist again", plain_ok and "✓ read the parser".encode() in plain, plain[-300:])
    os.kill(px, signal.SIGKILL)
    os.waitpid(px, 0)
    srvx.kill()


todo_hidden()


class Screen:
    """Just enough of a terminal for awl's inline live area: text, CR, LF, CSI A/J/K, SGR and DEC modes ignored."""
    def __init__(self, rows, cols):
        self.rows, self.cols, self.lines, self.y, self.x = rows, cols, [""], 0, 0

    def feed(self, data):
        s = data.decode("utf-8", "replace")
        i = 0
        while i < len(s):
            c = s[i]
            if c == "\x1b":
                m = re.match(r"\x1b\[([?0-9;]*)([A-Za-z])", s[i:])
                if not m:
                    i += 1
                    continue
                arg, op = m.group(1), m.group(2)
                n = int(arg) if arg.isdigit() else 1
                if op == "A":
                    self.y = max(0, self.y - n)
                elif op == "J":
                    self.lines = self.lines[:self.y + 1]
                    self.lines[self.y] = self.lines[self.y][:self.x]
                elif op == "K":
                    self.lines[self.y] = self.lines[self.y][:self.x]
                i += len(m.group(0))
                continue
            if c == "\r":
                self.x = 0
            elif c == "\n":
                self.y += 1
                if self.y == len(self.lines):
                    self.lines.append("")
            elif c >= " ":
                l = self.lines[self.y].ljust(self.x)
                self.lines[self.y] = l[:self.x] + c + l[self.x + 1:]
                self.x += 1
                if self.x > self.cols:
                    self.overflow = True
            i += 1

    def tail(self, n):
        return [l.rstrip() for l in self.lines[-n:]]


def think_view():
    """Issue #1: while the model reasons, the newest reasoning shows as word-wrapped rows above the timer line,
    the rows never run past the terminal width, and the whole area collapses to one "∴ thought" line afterward."""
    d = tempfile.mkdtemp()
    words = ("parse the header then check every field against the spec and note where the length "
             "prefix disagrees with the payload size before deciding on a fix ").split()
    reasoning = " ".join(words[i % len(words)] + (str(i) if i % 7 == 0 else "") for i in range(260))
    sp8 = os.path.join(d, "s.json")
    json.dump([{"reasoning": reasoning, "content": "think done", "pace": 0.008}], open(sp8, "w"))
    for rows_env, label in (("", "default rows"), ("0", "AWL_THINK_ROWS=0")):
        srv8 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp8], stdout=subprocess.PIPE)
        port8 = srv8.stdout.readline().decode().strip()
        e8 = dict(env, AWL_URL=f"http://127.0.0.1:{port8}", XDG_STATE_HOME=os.path.join(d, "state"))
        if rows_env:
            e8["AWL_THINK_ROWS"] = rows_env
        p8, f8 = pty.fork()
        if p8 == 0:
            os.chdir(d)
            os.execve(AWL, [AWL], e8)
        fcntl.ioctl(f8, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        scr = Screen(24, 80)
        mid, most, widest = None, 0, 0
        def pump(until_pat, secs):
            nonlocal mid, most, widest
            got = b""
            end = time.time() + secs
            while until_pat not in got and time.time() < end:
                if select.select([f8], [], [], 0.05)[0]:
                    chunk = os.read(f8, 65536)
                    got += chunk
                    scr.feed(chunk)
                    shown = [l for l in scr.tail(10) if l.startswith("  ") and len(l) > 20]
                    if "∴" in "".join(scr.tail(1)) and len(shown) > most:
                        most, mid = len(shown), list(scr.tail(10))
                    widest = max(widest, max(len(l) for l in scr.lines))
            return got
        pump(b"\xe2\x80\xba ", 2)
        os.write(f8, b"go\r")
        out = pump(b"think done", 10)
        final = [l for l in scr.tail(8) if l]
        if not rows_env:
            check("live reasoning: several wrapped rows above the timer", most >= 4 and most <= 6, f"{most} rows; {mid}")
            check("live reasoning: no row wider than the terminal", widest <= 80 and not getattr(scr, "overflow", False), widest)
            rows8 = [l[2:] for l in (mid or []) if l.startswith("  ") and not l.startswith("   ")]
            check("live reasoning: rows are consecutive text, wrapped at words", len(rows8) >= 4 and " ".join(rows8[:-1]) in reasoning, rows8)
            check("live reasoning: frames are synchronized", b"\x1b[?2026h" in out and b"\x1b[?2026l" in out, out[:200])
            check("live reasoning: collapses to one line after the turn", any("∴ thought" in l for l in final) and not any(l.startswith("  ") and "parse" in l for l in final), final)
        else:
            check("AWL_THINK_ROWS=0: timer line only", most == 0 and any("∴ thought" in l for l in final), f"{most} rows; {final}")
        os.kill(p8, signal.SIGKILL)
        os.waitpid(p8, 0)
        srv8.kill()


think_view()


def forming_view():
    """A tool call streaming in shows its name and size on the live line; the reasoning folds first."""
    d = tempfile.mkdtemp()
    body = "x" * 12000
    sp9 = os.path.join(d, "s.json")
    json.dump([{"reasoning": "plan the page", "tool_calls": [{"name": "write", "arguments": {"path": "big.html", "content": body}}], "pace": 0.0012},
               {"content": "formed ok"}], open(sp9, "w"))
    srv9 = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp9], stdout=subprocess.PIPE)
    port9 = srv9.stdout.readline().decode().strip()
    p9, f9 = pty.fork()
    if p9 == 0:
        os.chdir(d)
        os.execve(AWL, [AWL], dict(env, AWL_URL=f"http://127.0.0.1:{port9}", XDG_STATE_HOME=os.path.join(d, "state")))
    fcntl.ioctl(f9, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    out = b""
    end = time.time() + 2
    while b"\xe2\x80\xba " not in out and time.time() < end:
        if select.select([f9], [], [], 0.05)[0]:
            out += os.read(f9, 65536)
    os.write(f9, b"go\r")
    out = b""
    end = time.time() + 15
    while b"formed ok" not in out and time.time() < end:
        if select.select([f9], [], [], 0.05)[0]:
            out += os.read(f9, 65536)
    plain = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out)
    check("forming tool call: name and size on the live line", re.search(rb"\xc2\xb7 write \d+ KB", plain) is not None, plain[-300:])
    check("forming tool call: reasoning folded before it", plain.find("∴ thought".encode()) != -1 and plain.find("∴ thought".encode()) < plain.find(b"\xc2\xb7 write"), plain[:300])
    check("forming tool call: the call still runs", os.path.exists(os.path.join(d, "big.html")) and b"formed ok" in out, plain[-200:])
    os.kill(p9, signal.SIGKILL)
    os.waitpid(p9, 0)
    srv9.kill()


forming_view()


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

    def after_leave(pat, t=3.0):  # `pat` printed after the switch back to the normal screen
        end = time.time() + t
        while time.time() < end:
            parts = out[0].split(b"\x1b[?1049l", 1)
            if len(parts) == 2 and pat.encode() in parts[1]:
                return True
            if select.select([f7], [], [], 0.05)[0]:
                try:
                    out[0] += os.read(f7, 65536)
                except OSError:
                    break
        return False

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
    check("/full leaves: transcript printed on the normal screen", after_leave("row 60") and b"short reply" in out[0].split(b"\x1b[?1049l", 1)[1], out[0][-200:])
    out[0] = b""
    os.write(f7, b"/full\r")
    check("/full enters again", until("\x1b[?1049h"), out[0][-100:])
    os.write(f7, b"x\r")
    until("after toggle")
    out[0] = b""
    os.write(f7, b"\x04")  # Ctrl-D quits
    check("quitting prints the transcript and restores the screen", after_leave("after toggle"), out[0][-200:])
    try:
        os.waitpid(p7, 0)
    except ChildProcessError:
        pass
    srv7.kill()


full_screen()


def agents_view():
    """Background agents (--bg) and the ← view: status files, steering, approvals, stop, crash, and the dashboard's actions."""
    d = tempfile.mkdtemp()
    proj = os.path.join(d, "proj")
    os.makedirs(proj)
    state = os.path.join(d, "state")
    sess = os.path.join(state, "awl", "sessions")
    slow = os.path.join(d, "slow.json")
    json.dump([{"tool_calls": [{"name": "bash", "arguments": {"command": "sleep 1"}}]}], open(slow, "w"))
    quick = os.path.join(d, "quick.json")
    json.dump([{"content": "quick answer"}], open(quick, "w"))
    srv_s = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), slow], stdout=subprocess.PIPE)
    srv_q = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), quick], stdout=subprocess.PIPE)
    slow_url = "http://127.0.0.1:" + srv_s.stdout.readline().decode().strip()
    quick_url = "http://127.0.0.1:" + srv_q.stdout.readline().decode().strip()
    base = dict(env, XDG_STATE_HOME=state, AWL_SANDBOX="off")
    procs = []

    def bg(prompt, url, **extra):
        p = subprocess.Popen([AWL, "--bg", "-p", prompt], cwd=proj, env=dict(base, AWL_URL=url, **extra),
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)
        return p

    def session_of(prompt, t=5.0):
        end = time.time() + t
        while time.time() < end:
            for f in sorted(os.listdir(sess)) if os.path.isdir(sess) else []:
                if f.endswith(".jsonl") and prompt in open(os.path.join(sess, f)).read():
                    return os.path.join(sess, f)[:-6]
            time.sleep(0.1)
        return None

    def live(b):
        try:
            return json.load(open(b + ".live"))
        except (OSError, ValueError):
            return {}

    def wait_state(b, want, t=6.0):
        end = time.time() + t
        while time.time() < end:
            if live(b).get("state") == want:
                return True
            time.sleep(0.1)
        return False

    # --bg on its own: status file, steering through the inbox, a clean finish
    bg("steer me", slow_url, AWL_MAX_STEPS="3")
    b1 = session_of("steer me")
    check("--bg: status file says running, kind bg", b1 is not None and wait_state(b1, "running") and live(b1).get("kind") == "bg", live(b1) if b1 else "no session")
    open(b1 + ".inbox", "w").write("and also this")
    end = time.time() + 6
    while time.time() < end and "and also this" not in open(b1 + ".jsonl").read():
        time.sleep(0.1)
    check("--bg: a message in the inbox reaches the model as a user turn", '"content":"and also this"' in open(b1 + ".jsonl").read() and not os.path.exists(b1 + ".inbox"), open(b1 + ".jsonl").read()[-300:])
    check("--bg: max steps ends as failed, status kept", wait_state(b1, "failed", 8), live(b1))
    # an approval answered through the answer file
    ask = bg("needs approval", slow_url, AWL_MODE="ask")
    b2 = session_of("needs approval")
    check("--bg ask mode: waits with the question in its status", b2 is not None and wait_state(b2, "waiting") and "run a command: bash sleep 1" in live(b2).get("ask", ""), live(b2) if b2 else "")
    open(b2 + ".answer", "w").write("y")
    check("--bg: answer y lets the command run", wait_state(b2, "running", 3) or '"role":"tool"' in open(b2 + ".jsonl").read(), live(b2))
    # killed hard: nobody holds the lock, so the dashboard must not say running
    victim = bg("killed hard", slow_url)
    b3 = session_of("killed hard")
    wait_state(b3, "running")
    victim.kill()
    victim.wait()

    try:
        tui_part(proj, base, quick_url, slow_url, sess, bg, session_of, live, wait_state, b1, b2)
    finally:
        for p in procs:
            if p.poll() is None:
                p.kill()
        srv_s.kill()
        srv_q.kill()


def tui_part(proj, base, quick_url, slow_url, sess, bg, session_of, live, wait_state, b1, b2):
    pid, f = pty.fork()
    if pid == 0:
        os.chdir(proj)
        os.execve(AWL, [AWL], dict(base, AWL_URL=quick_url))
    fcntl.ioctl(f, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    out = [b""]
    import threading

    def drain():  # read the terminal all the time: the view redraws while the test waits on files
        while True:
            try:
                if select.select([f], [], [], 0.05)[0]:
                    out[0] += os.read(f, 1 << 20)
            except OSError:
                return

    threading.Thread(target=drain, daemon=True).start()

    def until(pat, t=4.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            time.sleep(0.03)
        return pat.encode() in out[0]

    def plain():
        return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", out[0]).decode("utf-8", "replace")

    check("status line counts agents that need you", until("? 1 needs you"), plain()[-300:])
    out[0] = b""
    os.write(f, b"\x1b[D")  # ← at an empty prompt
    check("← opens the agents view on the alternate screen", until("agents & sessions") and b"\x1b[?1049h" in out[0], plain()[-300:])
    check("view: groups, the waiting agent first, its question", until("NEEDS YOU") and until("wants to run a command: bash sleep 1"), plain()[-600:])
    check("view: a killed agent shows as failed, not running", until("killed hard") and ("ended unexpectedly" in plain() or "✗ killed hard" in plain()), plain()[-800:])
    out[0] = b""
    os.write(f, b"y")
    check("y answers the waiting agent", until("allowed") and wait_state(b2, "running", 3), live(b2))
    # stop: select the running agent (the one that just got its answer stays selected)
    out[0] = b""
    os.write(f, b"x")
    check("x stops a running background agent", until("stopping") and wait_state(b2, "stopped", 6), live(b2))
    # a new agent from the view
    out[0] = b""
    os.write(f, b"n")
    until("new background agent")
    os.write(f, b"brand new task\r")
    b4 = session_of("brand new task")
    check("n starts a background agent in this folder", until("started a background agent") and b4 is not None and wait_state(b4, "done", 6), live(b4) if b4 else plain()[-300:])
    out[0] = b""
    check("the new agent is selected when it shows up", until("brand new task", 4) and until("✓ done", 4), plain()[-600:])
    os.write(f, b"r\x15renamed task\r")
    time.sleep(0.6)
    check("r renames (a .title file)", b4 is not None and os.path.exists(b4 + ".title") and open(b4 + ".title").read() == "renamed task", "")
    out[0] = b""
    os.write(f, b"f")
    check("f forks and opens the fork here", until("resumed") and until("renamed task (fork)"), plain()[-400:])
    os.write(f, b"\x1b[D")
    until("agents & sessions")
    os.write(f, b"/renamed task (fork)\r")
    time.sleep(0.3)
    out[0] = b""
    os.write(f, b"\x7f")
    until("delete this session?")
    os.write(f, b"y")
    check("⌫ then y: refused for the session at the prompt", until("in use") or until("delete this session?", 0.5) is False, plain()[-300:])
    os.write(f, b"\x1b")
    os.write(f, b"\x1b")
    time.sleep(0.4)
    out[0] = b""
    os.write(f, b"\x1b[D")
    until("agents & sessions")
    os.write(f, b"/steer me\r")
    time.sleep(0.3)
    out[0] = b""
    os.write(f, b"\x7f")
    until("delete this session?")
    os.write(f, b"y")
    check("⌫ then y deletes a finished session and its files", until("deleted") and not os.path.exists(b1 + ".jsonl") and not os.path.exists(b1 + ".live"), plain()[-300:])
    os.write(f, b"\x1b")  # the first Esc clears the search
    time.sleep(0.3)
    out[0] = b""
    os.write(f, b"\x1b")
    check("Esc leaves the view: normal screen, prompt again", until("\x1b[?1049l") and until("› "), out[0][-200:])
    # opening a session that a background agent is still using is refused
    busy = bg("still busy", slow_url)
    b5 = session_of("still busy")
    wait_state(b5, "running")
    r = subprocess.run([AWL, "-r", b5 + ".jsonl"], cwd=proj, env=dict(base, AWL_URL=quick_url), capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
    check("awl -r on a session a background agent is using: refused", r.returncode != 0 and "in use by another awl" in r.stderr, r.stderr)
    busy.kill()
    # /bg from the prompt, and the note when it finishes
    out[0] = b""
    os.write(f, b"/bg tell me a joke\r")
    check("/bg starts an agent; a note says when it finished", until("background agent started") and until("finished · ← to see it", 8), plain()[-400:])
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)


agents_view()


def rewind_and_editor():
    """Ctrl-G writes the prompt in $EDITOR; Esc Esc rewinds to an earlier prompt, puts files back, keeps the old conversation."""
    d = tempfile.mkdtemp()
    proj = os.path.join(d, "proj")
    os.makedirs(proj)
    state = os.path.join(d, "state")
    sess = os.path.join(state, "awl", "sessions")
    ed = os.path.join(d, "ed.sh")
    open(ed, "w").write('#!/bin/sh\nprintf "%s and more from the editor\\n\\n" "$(cat "$1")" > "$1"\n')
    os.chmod(ed, 0o755)
    turns = [
        {"tool_calls": [{"name": "write", "arguments": {"path": "a.txt", "content": "one\n"}}]},
        {"content": "wrote one"},
        {"tool_calls": [{"name": "edit", "arguments": {"path": "a.txt", "old_string": "one", "new_string": "two"}}]},
        {"content": "made it two"},
        {"content": "again"},
    ]
    sp = os.path.join(d, "s.json")
    json.dump(turns, open(sp, "w"))
    lg = os.path.join(d, "req.jsonl")
    srv_r = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp, "--log", lg], stdout=subprocess.PIPE)
    url = "http://127.0.0.1:" + srv_r.stdout.readline().decode().strip()
    pid, f = pty.fork()
    if pid == 0:
        os.chdir(proj)
        os.execve(AWL, [AWL], dict(env, XDG_STATE_HOME=state, AWL_SANDBOX="off", AWL_URL=url, EDITOR=ed, VISUAL=""))
    fcntl.ioctl(f, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    out = [b""]
    import threading

    def drain():
        while True:
            try:
                if select.select([f], [], [], 0.05)[0]:
                    out[0] += os.read(f, 1 << 20)
            except OSError:
                return

    threading.Thread(target=drain, daemon=True).start()

    def until(pat, t=4.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            time.sleep(0.03)
        return pat.encode() in out[0]

    try:
        until("› ")
        os.write(f, b"start")
        time.sleep(0.2)
        os.write(f, b"\x07")  # Ctrl-G
        check("Ctrl-G: the prompt comes back from $EDITOR", until("start and more from the editor"), out[0][-300:])
        os.write(f, b"\r")
        until("wrote one")
        reqs = [json.loads(l) for l in open(lg)]
        check("Ctrl-G: the edited prompt is what is sent", reqs and reqs[0]["messages"][-1]["content"] == "start and more from the editor", reqs[0]["messages"][-1] if reqs else "")
        until("› ", 2)
        os.write(f, b"make it two\r")
        until("made it two")
        check("setup: a.txt changed twice", open(os.path.join(proj, "a.txt")).read() == "two\n", "")
        time.sleep(0.3)
        out[0] = b""
        os.write(f, b"\x1b")
        time.sleep(0.3)
        check("Esc at an empty prompt: the status line says esc again to rewind", until("esc again to rewind"), out[0][-200:])
        os.write(f, b"\x1b")
        check("Esc Esc: picker of earlier prompts, newest first", until("rewind to before this prompt") and until("make it two  (last)"), out[0][-300:])
        os.write(f, b"\r")  # before "make it two"
        check("then: conversation and files, or conversation only", until("conversation and files"), out[0][-300:])
        os.write(f, b"\r")
        check("rewind put the file back and kept the old conversation", until("put back 1 file") and until("(before rewind)"), out[0][-400:])
        check("rewind: a.txt as it was before that prompt", open(os.path.join(proj, "a.txt")).read() == "one\n", open(os.path.join(proj, "a.txt")).read())
        titles = [open(os.path.join(sess, x)).read() for x in os.listdir(sess) if x.endswith(".title")]
        check("rewind: the old session is titled ... (before rewind)", any(t.endswith("(before rewind)") for t in titles), titles)
        os.write(f, b"\r")  # the prompt came back in the input: send it again
        until("again")
        reqs = [json.loads(l) for l in open(lg)]
        last = reqs[-1]["messages"]
        users = [m["content"] for m in last if m["role"] == "user"]
        check("rewind: the prompt returns to the input, and the history ends before it", users == ["start and more from the editor", "make it two"], users)
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        srv_r.kill()


rewind_and_editor()


def prompt_commands():
    """/NAME runs a saved prompt (front matter dropped, $1 and $ARGUMENTS filled); /review is built in; Tab completes names."""
    d = tempfile.mkdtemp()
    cfg = os.path.join(d, "cfg")
    os.makedirs(os.path.join(cfg, "awl", "prompts"))
    open(os.path.join(cfg, "awl", "prompts", "fixit.md"), "w").write("---\ndescription: fix one thing\n---\nFix $1 now. Context: $ARGUMENTS\n")
    sp = os.path.join(d, "s.json")
    json.dump([{"content": "on it"}], open(sp, "w"))
    lg = os.path.join(d, "req.jsonl")
    srv_p = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp, "--log", lg], stdout=subprocess.PIPE)
    url = "http://127.0.0.1:" + srv_p.stdout.readline().decode().strip()
    pid, f = pty.fork()
    if pid == 0:
        os.chdir(d)
        os.execve(AWL, [AWL], dict(env, XDG_STATE_HOME=os.path.join(d, "state"), XDG_CONFIG_HOME=cfg, AWL_SANDBOX="off", AWL_URL=url))
    fcntl.ioctl(f, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    out = [b""]

    def until(pat, t=4.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            if select.select([f], [], [], 0.05)[0]:
                try:
                    out[0] += os.read(f, 1 << 20)
                except OSError:
                    break
        return pat.encode() in out[0]

    def last_user():
        reqs = [json.loads(l) for l in open(lg)] if os.path.exists(lg) else []
        return reqs[-1]["messages"][-1]["content"] if reqs else ""

    try:
        until("› ")
        os.write(f, b"/fi\t")
        check("Tab completes a prompt command's name", until("/fixit "), out[0][-200:])
        os.write(f, b"parser quickly\r")
        until("on it")
        check("/fixit: front matter dropped, $1 and $ARGUMENTS filled", last_user() == "Fix parser now. Context: parser quickly", last_user())
        out[0] = b""
        os.write(f, b"/review focus on the parser\r")
        until("on it")
        u = last_user()
        check("/review is built in; the words after it are added", u.startswith("Review the changes in this repository") and u.endswith("Do not change any files.\nfocus on the parser"), u[-200:])
        out[0] = b""
        os.write(f, b"/help\r")
        check("/help lists prompt commands", until("/fixit") and until("/review") and until("/init"), out[0][-400:])
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        srv_p.kill()


prompt_commands()


def prefix_diff_title():
    """Ask mode: p allows a command prefix for the session (chained commands still ask); /diff; the terminal title."""
    d = tempfile.mkdtemp()
    proj = os.path.join(d, "proj")
    os.makedirs(proj)
    g = lambda *a: subprocess.run(["git", "-C", proj, "-c", "user.email=t@t", "-c", "user.name=t", *a], capture_output=True)
    g("init", "-q")
    open(os.path.join(proj, "a.txt"), "w").write("one\n")
    g("add", ".")
    g("commit", "-qm", "init")
    open(os.path.join(proj, "a.txt"), "w").write("one\nadded line\n")
    open(os.path.join(proj, "new.txt"), "w").write("brand new\n")
    bash = lambda c: {"tool_calls": [{"name": "bash", "arguments": {"command": c}}]}
    turns = [bash("echo one"), {"content": "first ok"}, bash("echo two"), {"content": "second ok"}, bash("echo three && echo x"), {"content": "third ok"}]
    sp = os.path.join(d, "s.json")
    json.dump(turns, open(sp, "w"))
    srv_x = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_sse.py"), sp], stdout=subprocess.PIPE)
    url = "http://127.0.0.1:" + srv_x.stdout.readline().decode().strip()
    pid, f = pty.fork()
    if pid == 0:
        os.chdir(proj)
        os.execve(AWL, [AWL], dict(env, XDG_STATE_HOME=os.path.join(d, "state"), AWL_SANDBOX="off", AWL_URL=url, AWL_MODE="ask"))
    fcntl.ioctl(f, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
    out = [b""]

    def until(pat, t=4.0):
        end = time.time() + t
        while pat.encode() not in out[0] and time.time() < end:
            if select.select([f], [], [], 0.05)[0]:
                try:
                    out[0] += os.read(f, 1 << 20)
                except OSError:
                    break
        return pat.encode() in out[0]

    try:
        check("title: the terminal's title is kept to put back, then set", until("\x1b]2;proj · awl\x07") and b"\x1b[22;2t" in out[0], out[0][:200])
        os.write(f, b"go\r")
        check("ask mode offers the command's prefix", until("p = always `echo` here"), out[0][-300:])
        check("title: ? while it waits for you", until("\x1b]2;? proj · awl\x07"), out[0][-300:])
        check("title: ⋯ while it works", "\x1b]2;⋯ proj · awl\x07".encode() in out[0], out[0][-200:])
        os.write(f, b"p")
        until("first ok")
        out[0] = b""
        os.write(f, b"again\r")
        until("second ok")
        check("p: the same prefix runs without asking", b"allow?" not in out[0] and b"\xe2\x96\xb8 bash" in out[0], out[0][-300:])
        out[0] = b""
        os.write(f, b"chain\r")
        check("a chained command with that prefix still asks", until("allow?"), out[0][-300:])
        os.write(f, b"n")
        until("third ok")
        out[0] = b""
        os.write(f, b"/diff\r")
        plain_ok = until("2 files changed")
        check("/diff: tracked changes and new files, colored", plain_ok and (ui_green := b"+added line") in out[0] and b"+brand new" in out[0] and b"\x1b[1mdiff --git" in out[0], out[0][-600:])
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        srv_x.kill()


prefix_diff_title()
print(f"tui: {'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
