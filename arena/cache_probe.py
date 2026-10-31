#!/usr/bin/env python3
"""Does the model server reuse its prefix cache, and for which request shapes?

  arena/cache_probe.py [--upstream http://127.0.0.1:12434] [--model M] [--tokens 12000]

Sends, in order, and prints prompt / cached tokens and time to first byte for each:
  1 base       system + a long user message + an assistant turn (cold)
  2 same       the identical request again (should be ~all cached)
  3 +instr     the same messages + one more user message (the shape of a same-prefix summary request)
  4 serialized the same text re-packed into one user message (today's compact() request shape)
  5 parallel   two different-suffix requests on the same prefix at once (cache under concurrency)
  6 ext x2     two requests at once, each extending the whole previous prompt (async summary + next step)
  7 step+1     the next step after that, extending the step branch
"cached" comes from usage.prompt_tokens_details.cached_tokens; a server that does not report it shows
"-", and then the time to first byte is the only signal (a hit prefills in a fraction of the time).
"""
import http.client
import json
import os
import sys
import threading
import time
from urllib.parse import urlsplit


def arg(n, d):
    return sys.argv[sys.argv.index(n) + 1] if n in sys.argv else d


UP = urlsplit(arg("--upstream", "http://127.0.0.1:12434"))
KEYF = os.path.expanduser("~/.local/state/omarchy/local-ai/gateway.key")
KEY = open(KEYF).read().strip() if os.path.exists(KEYF) else ""
N = int(arg("--tokens", "12000"))


def post(body):
    c = (http.client.HTTPSConnection if UP.scheme == "https" else http.client.HTTPConnection)(UP.hostname, UP.port, timeout=900)
    t0 = time.time()
    c.request("POST", UP.path.rstrip("/") + "/v1/chat/completions", json.dumps(body), {"Content-Type": "application/json", "Authorization": "Bearer " + KEY})
    r = c.getresponse()
    ttfb = None
    usage = {}
    buf = b""
    while True:
        ch = r.read1(65536)
        if not ch:
            break
        if ttfb is None:
            ttfb = time.time() - t0
        buf += ch
    for l in buf.split(b"\n"):
        l = l.strip()
        if l.startswith(b"data:") and l[5:].strip() not in (b"", b"[DONE]"):
            try:
                o = json.loads(l[5:])
            except ValueError:
                continue
            if o.get("usage"):
                usage = o["usage"]
    if r.status != 200:
        print("HTTP", r.status, buf[:300])
    return usage, ttfb or 0.0


def model():
    m = arg("--model", None)
    if m:
        return m
    c = http.client.HTTPConnection(UP.hostname, UP.port, timeout=10)
    c.request("GET", "/v1/models", headers={"Authorization": "Bearer " + KEY})
    return json.loads(c.getresponse().read())["data"][0]["id"]


def show(name, u, t):
    d = u.get("prompt_tokens_details") or {}
    c = d.get("cached_tokens")
    print(f"{name:11} prompt {u.get('prompt_tokens', '?'):>6}  cached {c if c is not None else '-':>6}  ttfb {t:6.2f} s")


M = model()
salt = str(time.time())  # a fresh prefix each run, so run 1 is really cold
words = " ".join(f"line {i}: the value of key_{i} is {i * 7919 % 10007}." for i in range(N // 12))
sysm = {"role": "system", "content": "You are a test. " + salt}
msgs = [sysm, {"role": "user", "content": "Remember these facts.\n" + words},
        {"role": "assistant", "content": "Noted."}]
base = {"model": M, "stream": True, "stream_options": {"include_usage": True}, "max_tokens": 8,
        "chat_template_kwargs": {"enable_thinking": False}}
show("1 base", *post(dict(base, messages=msgs + [{"role": "user", "content": "Say ok."}])))
show("2 same", *post(dict(base, messages=msgs + [{"role": "user", "content": "Say ok."}])))
show("3 +instr", *post(dict(base, messages=msgs + [{"role": "user", "content": "Say ok."}, {"role": "assistant", "content": "ok"},
                                                    {"role": "user", "content": "Summarize the conversation so far."}])))
flat = "\n".join(f"[{m['role']}]: {m['content']}" for m in msgs[1:])
show("4 serial", *post(dict(base, messages=[sysm, {"role": "user", "content": "Summarize:\n" + flat}])))
res = [None, None]


def par(i):
    res[i] = post(dict(base, messages=msgs + [{"role": "user", "content": f"Say ok {i}."}]))


ts = [threading.Thread(target=par, args=(i,)) for i in range(2)]
for t in ts:
    t.start()
for t in ts:
    t.join()
show("5 par a", *res[0])
show("5 par b", *res[1])
# 6: two requests at once, each extending the whole previous prompt (C's shape: the agent's next step and
# the summary request both continue the same last request)
last = msgs + [{"role": "user", "content": "Say ok."}]
show("6 warm", *post(dict(base, messages=last)))


def ext(i, tail):
    res[i] = post(dict(base, messages=last + [{"role": "assistant", "content": "ok"}, {"role": "user", "content": tail}]))


ts = [threading.Thread(target=ext, args=(0, "Now say yes.")), threading.Thread(target=ext, args=(1, "Summarize the conversation so far."))]
for t in ts:
    t.start()
for t in ts:
    t.join()
show("6 step", *res[0])
show("6 summary", *res[1])
show("7 step+1", *post(dict(base, messages=last + [{"role": "assistant", "content": "ok"}, {"role": "user", "content": "Now say yes."},
                                                  {"role": "assistant", "content": "yes"}, {"role": "user", "content": "Again."}])))
