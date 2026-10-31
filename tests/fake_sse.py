#!/usr/bin/env python3
"""Deterministic OpenAI-compatible SSE server for tests (stdlib only).

Usage: fake_sse.py SCRIPT.json [--port N] [--log FILE] [--split N] [--mode chunked|length|close] [--comments 1]
SCRIPT is a list of turns, served in order (the last one repeats):
  {"reasoning": "...", "content": "...", "tool_calls": [{"name": "read", "arguments": {...}}],
   "status": 200, "delay": 0.0, "hang": false, "pace": 0.0}
"pace" (chunked mode) sends one event per chunk with that many seconds between them, like a live model.
Prints the bound port on stdout, then serves until killed.
Each request body is appended to --log as one JSON line, plus "_path" and "_auth" (the
Authorization header). --comments 1 interleaves OpenRouter-style ": OPENROUTER PROCESSING" lines.
--summary TURN.json: a request whose last message asks for awl's background summary (AWL_CTX_MODE=async)
gets this turn, outside the script order (it runs while the script goes on). --raw 1 also logs the
request body as sent ("_raw").
"""
import json
import re
import socket
import sys
import threading
import time

args = sys.argv[1:]
script = json.load(open(args[0]))
opt = {"--port": "0", "--log": "", "--split": "0", "--mode": "chunked", "--ctx": "0", "--comments": "0", "--models": "", "--summary": "", "--raw": "0"}
for i in range(1, len(args), 2):
    opt[args[i]] = args[i + 1]
split = int(opt["--split"])
mode = opt["--mode"]
summary_turn = json.load(open(opt["--summary"])) if opt["--summary"] else None
served = 0
lock = threading.Lock()


def events(turn, model, parts=False):
    def ev(delta, finish=None):
        return {"id": "x", "object": "chat.completion.chunk", "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
    out = [ev({"role": "assistant"})]
    r = turn.get("reasoning", "")
    for i in range(0, len(r), 5):
        out.append(ev({"reasoning_content": r[i:i + 5]}))
    c = turn.get("content", "")
    for i in range(0, len(c), 4):
        out.append(ev({"content": c[i:i + 4]}))
    for idx, tc in enumerate(turn.get("tool_calls", [])):
        a = tc["arguments"] if isinstance(tc["arguments"], str) else json.dumps(tc["arguments"])
        out.append(ev({"tool_calls": [{"index": idx, "id": f"call_{idx}", "type": "function",
                                       "function": {"name": tc["name"], "arguments": ""}}]}))
        for i in range(0, len(a), 7):
            out.append(ev({"tool_calls": [{"index": idx, "function": {"arguments": a[i:i + 7]}}]}))
    out.append(ev({}, turn.get("finish") or ("tool_calls" if turn.get("tool_calls") else "stop")))
    out.append({"id": "x", "choices": [], "usage": turn.get("usage") or {"prompt_tokens": 100 + served, "completion_tokens": 10}})
    sep = b": OPENROUTER PROCESSING\n\n" if int(opt["--comments"]) else b""
    if parts:
        return [b"data: " + json.dumps(e).encode() + b"\n\n" for e in out] + [b"data: [DONE]\n\n"]
    body = sep + b"".join(b"data: " + json.dumps(e).encode() + b"\n\n" + sep for e in out)
    return body + b"data: [DONE]\n\n"


def fill(turn, body):
    """Placeholders in a turn, taken from the request's tool results and user messages: "$VIEW" (the
    session view's path, the newest mention) and "$ELIDED_OFFSET" / "$ELIDED_LIMIT" (from the first elided tool output)."""
    t = json.dumps(turn)
    outs = "\n".join(x.get("content") or "" for x in json.loads(body).get("messages", []) if x.get("role") in ("tool", "user"))
    if "$VIEW" in t:
        m = re.findall(r'(/[^\s"\\]*/view-\d+\.txt)', outs)
        t = t.replace("$VIEW", m[-1] if m else "/no-view-in-request")
    if "$ELIDED_" in t:
        m = re.search(r"\(offset=(\d+), limit=(\d+)\)", outs)
        t = t.replace('"$ELIDED_OFFSET"', m.group(1) if m else "0").replace('"$ELIDED_LIMIT"', m.group(2) if m else "0")
    return json.loads(t)


def send(conn, data):
    if split <= 0:
        conn.sendall(data)
        return
    for i in range(0, len(data), split):
        conn.sendall(data[i:i + split])
        time.sleep(0.0005)


def handle(conn):
    global served
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                return
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        lines = head.decode().split("\r\n")
        method, path, _ = lines[0].split(" ", 2)
        hdrs = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        n = int(hdrs.get("content-length", "0"))
        while len(rest) < n:
            rest += conn.recv(65536)
        if path.endswith("/v1/models"):
            m = {"id": "fake-model"}
            if int(opt["--ctx"]):
                m["max_model_len"] = int(opt["--ctx"])
            extra = [{"id": x, "context_length": 64000} for x in opt["--models"].split(",") if x]
            body = json.dumps({"data": [m] + extra}).encode()
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            return
        req = json.loads(rest)
        last = (req.get("messages") or [{}])[-1]
        is_summary = summary_turn is not None and last.get("role") == "user" and str(last.get("content", "")).startswith("[awl: the conversation above")
        with lock:
            if is_summary:
                turn = summary_turn
            else:
                turn = fill(script[min(served, len(script) - 1)], rest.decode("utf-8", "replace"))
                served += 1
            if opt["--log"]:
                extra = {"_raw": rest.decode("utf-8", "replace")} if int(opt["--raw"]) else {}
                with open(opt["--log"], "a") as f:
                    f.write(json.dumps(dict(req, _path=path, _auth=hdrs.get("authorization", ""), **extra)) + "\n")
        if turn.get("delay"):
            time.sleep(turn["delay"])
        status = turn.get("status", 200)
        if status != 200:
            body = json.dumps({"error": {"message": turn.get("content", "boom")}}).encode()
            conn.sendall(b"HTTP/1.1 %d Err\r\nContent-Length: %d\r\n\r\n" % (status, len(body)) + body)
            return
        if turn.get("pace") and mode == "chunked":
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
            for part in events(turn, req.get("model", ""), parts=True):
                conn.sendall(b"%x\r\n" % len(part) + part + b"\r\n")
                time.sleep(turn["pace"])
            conn.sendall(b"0\r\n\r\n")
            return
        data = events(turn, req.get("model", ""))
        if mode == "chunked":
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
            wire = b""
            for i in range(0, len(data), 61):
                part = data[i:i + 61]
                wire += b"%x\r\n" % len(part) + part + b"\r\n"
            send(conn, wire + b"0\r\n\r\n")
        elif mode == "length":
            send(conn, b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %d\r\n\r\n" % len(data) + data)
        else:
            send(conn, b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n" + data)
        if turn.get("hang"):
            time.sleep(60)
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        conn.close()


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(opt["--port"])))
s.listen(16)
print(s.getsockname()[1], flush=True)
while True:
    c, _ = s.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
