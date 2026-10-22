#!/usr/bin/env python3
"""Replay one recorded model turn with one change at a time, to find what makes the
model write more. Reads the final request a harness sent (proxy/<run>.last.json), cuts
it just before assistant message N (so it is the request for turn N), and sends each
variant K times to the upstream, printing completion tokens and reasoning length.

  arena/replay.py RESULTS_DIR AWL_RUN PI_RUN TURN [--k 4] [--upstream URL]
  e.g. arena/replay.py arena/results/20261022-114258-010 awl-wrongfix-0 pi-wrongfix-0 5

Variants (all share awl's conversation up to that turn):
  awl          the request as awl sent it
  pi-system    pi's system prompt instead of awl's
  pi-tools     pi's tool definitions instead of awl's
  pi-params    + pi's reasoning_effort and max_completion_tokens
  pi-all       all three
  effort-low / effort-medium / effort-high   only reasoning_effort
  cap-8192     only max_completion_tokens
--variants a,b,c picks which to run.
"""
import json
import os
import statistics
import sys
import time
import urllib.request

args = sys.argv[1:]
opt = {"--k": "4", "--upstream": "http://127.0.0.1:12434", "--variants": "awl,pi-system,pi-tools,pi-params,pi-all"}
pos = []
i = 0
while i < len(args):
    if args[i] in opt:
        opt[args[i]] = args[i + 1]
        i += 2
    else:
        pos.append(args[i])
        i += 1
res, awl_run, pi_run, turn = pos[0], pos[1], pos[2], int(pos[3])
awl = json.load(open(os.path.join(res, "proxy", awl_run + ".last.json")))
pi = json.load(open(os.path.join(res, "proxy", pi_run + ".last.json")))

# the request for turn N: everything before the N-th assistant message
msgs, seen = [], 0
for m in awl["messages"]:
    if m["role"] == "assistant":
        seen += 1
        if seen == turn:
            break
    msgs.append(m)
assert seen == turn, f"awl's run has only {seen} assistant turns"
key = open(os.path.expanduser("~/.local/state/omarchy/local-ai/gateway.key")).read().strip()


def variant(name):
    body = {"model": awl["model"], "messages": [dict(m) for m in msgs], "tools": awl["tools"], "stream": False}
    if name in ("pi-system", "pi-all"):
        body["messages"][0] = pi["messages"][0]
    if name in ("pi-tools", "pi-all"):
        body["tools"] = pi["tools"]
    if name in ("pi-params", "pi-all"):
        for k in ("reasoning_effort", "max_completion_tokens"):
            if k in pi:
                body[k] = pi[k]
    if name.startswith("effort-"):  # effort-low, effort-medium, effort-high
        body["reasoning_effort"] = name[7:]
    if name == "cap-8192":
        body["max_completion_tokens"] = 8192
    return body


def send(body):
    req = urllib.request.Request(opt["--upstream"] + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + key})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=600))
    msg = r["choices"][0]["message"]
    reason = msg.get("reasoning_content") or msg.get("reasoning") or ""
    return r["usage"]["completion_tokens"], len(reason), time.time() - t0


print(f"turn {turn} of {awl_run}: {len(msgs)} messages; k={opt['--k']}")
names = opt.get("--variants", "awl,pi-system,pi-tools,pi-params,pi-all").split(",")
for name in names:
    toks, reasons, secs = [], [], []
    for _ in range(int(opt["--k"])):
        t, r, s = send(variant(name))
        toks.append(t)
        reasons.append(r)
        secs.append(s)
    print(f"{name:10} completion tokens median {statistics.median(toks):6.0f}  {toks}  reasoning chars median {statistics.median(reasons):6.0f}  secs {sum(secs):5.1f}", flush=True)
