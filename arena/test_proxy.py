#!/usr/bin/env python3
"""Offline test of proxy.py's hosted mode (OpenRouter) against tests/fake_sse.py. No network, no key.

  python3 arena/test_proxy.py [path/to/awl]
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
AWL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "zig-out/bin/awl")
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f": {detail}"))
    fails += not cond


def start(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    return p, int(p.stdout.readline())


with tempfile.TemporaryDirectory() as w:
    script = os.path.join(w, "s.json")
    json.dump([{"status": 429, "content": "slow down"},
               {"reasoning": "hmm", "content": "ok there", "usage": {"prompt_tokens": 50, "completion_tokens": 5, "cost": 0.0012}},
               {"content": "awl ok"}], open(script, "w"))
    keyf = os.path.join(w, "k")
    open(keyf, "w").write("sk-test\n")
    log, out = os.path.join(w, "up.jsonl"), os.path.join(w, "proxy")
    fake, fport = start([sys.executable, os.path.join(REPO, "tests/fake_sse.py"), script, "--log", log, "--comments", "1"])
    proxy, pport = start([sys.executable, os.path.join(ROOT, "proxy.py"), "--upstream", f"http://127.0.0.1:{fport}/api",
                          "--out", out, "--key-file", keyf, "--model", "vendor/model-x", "--ctx", "1234", "--provider", "P"])
    base = f"http://127.0.0.1:{pport}/run/r1"
    try:
        m = json.load(urllib.request.urlopen(base + "/v1/models"))
        check("models answered locally", m["data"] == [{"id": "vendor/model-x", "object": "model", "max_model_len": 1234}], m)

        body = json.dumps({"model": "whatever", "stream": True, "reasoning_effort": "medium", "include_reasoning": True,
                           "messages": [{"role": "user", "content": "hi"}]}).encode()
        req = urllib.request.Request(base + "/v1/chat/completions", body, {"Authorization": "Bearer dummy",
                                                                           "Content-Type": "application/json"})
        t0 = time.time()
        text = urllib.request.urlopen(req).read().decode()
        said = "".join(json.loads(l[5:])["choices"][0]["delta"].get("content", "") for l in text.splitlines()
                       if l.startswith("data: {") and json.loads(l[5:]).get("choices"))
        check("429 retried, then streamed", said == "ok there" and time.time() - t0 >= 1.5, said)
        check("comment lines passed through", ": OPENROUTER PROCESSING" in text)

        ups = [json.loads(l) for l in open(log)]
        u = ups[-1]
        check("path prefix", u["_path"] == "/api/v1/chat/completions", u["_path"])
        check("real key swapped in", u["_auth"] == "Bearer sk-test", u["_auth"])
        check("model forced", u["model"] == "vendor/model-x", u["model"])
        check("reasoning params dropped", "reasoning_effort" not in u and "include_reasoning" not in u, list(u))
        check("provider pinned", u.get("provider") == {"order": ["P"], "allow_fallbacks": False}, u.get("provider"))
        check("usage requested", u.get("stream_options") == {"include_usage": True}, u.get("stream_options"))
        check("no /models sent upstream", all(not x["_path"].endswith("/models") for x in ups))

        rec = [json.loads(l) for l in open(os.path.join(out, "r1.jsonl"))][-1]
        check("record: tokens, cost, retries, reasoning",
              rec["prompt_tokens"] == 50 and rec["cost"] == 0.0012 and rec["retries"] == 1 and rec["reasoning_chars"] == 3, rec)

        env = dict(os.environ, AWL_URL=f"http://127.0.0.1:{pport}/run/r2", AWL_KEY="dummy",
                   XDG_STATE_HOME=os.path.join(w, "state"))
        r = subprocess.run([AWL, "-p", "hi"], capture_output=True, text=True, env=env, cwd=w, timeout=30)
        check("awl end to end through hosted proxy", r.returncode == 0 and r.stdout.strip() == "awl ok", r.stdout + r.stderr)
        sysmsg = [json.loads(l) for l in open(log)][-1]["messages"][0]["content"]
        check("sandbox outside any repo: no AGENTS.md in awl's system prompt", "AGENTS.md" not in sysmsg, sysmsg[-300:])
    finally:
        proxy.kill()
        fake.kill()

print(f"test_proxy: {'all ok' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
