#!/usr/bin/env python3
"""Recall probe: after the context resets, can the model still give exact strings from the dropped part?

  arena/recall.py SESSION.jsonl QUESTIONS.json [--ctx 16000] [--modes retrieval,summary] [--reps 1]
                  [--upstream URL|openrouter] [--model M] [--budget USD]

For each mode and question, awl resumes a copy of SESSION with a window of --ctx tokens (the proxy
tells it so), which forces the reset before the first request; the question is the new prompt.
retrieval = awl's default (fresh context + the session view to grep); summary = AWL_COMPACT=summary
(the model writes a summary first). A question scores when its answer appears verbatim in the reply
(whitespace and quotes normalized). Before any model call, a dry run against tests/fake_sse.py shows
what the first request keeps after the reset (the kept tail is the same in both modes); a question
whose answer is still in it was not dropped: reported as "leak" and not scored. Prints recall, wall time, tokens and cost per mode.
QUESTIONS: [{"q": "...", "a": "exact answer"}]. arena/recall/make_session.py writes a synthetic pair.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
OR_KEY = os.path.expanduser("~/.local/state/awl-arena/openrouter.key")


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def norm(s):
    return " ".join(s.replace("“", '"').replace("”", '"').replace("’", "'").replace("`", "").split()).lower()


def run_awl(awl, session, prompt, url, extra, timeout=900):
    """awl resumes a copy of `session` and answers `prompt`. Returns (completed process, wall seconds)."""
    wd = tempfile.mkdtemp(prefix="awl-recall-")
    sdir = os.path.join(wd, "state", "awl", "sessions")
    os.makedirs(sdir)
    copy = os.path.join(sdir, "20200101-000000-1.jsonl")
    shutil.copy(session, copy)
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(wd, "state"), AWL_URL=url, AWL_MAX_STEPS="20", HOME=wd, **extra)
    if "AWL_COMPACT" not in extra:
        env.pop("AWL_COMPACT", None)
    t0 = time.time()
    try:
        p = subprocess.run([awl, "-r", copy, "-p", prompt], cwd=wd, env=env, capture_output=True, text=True, timeout=timeout)
    finally:
        shutil.rmtree(wd, ignore_errors=True)
    return p, time.time() - t0


def kept(awl, session, prompts, ctx):
    """The first request's messages after the reset, per prompt (no model: tests/fake_sse.py)."""
    w = tempfile.mkdtemp(prefix="awl-recall-dry-")
    json.dump([{"content": "ok"}], open(os.path.join(w, "s.json"), "w"))
    out = []
    try:
        for pr in prompts:
            log = os.path.join(w, "log.jsonl")
            if os.path.exists(log):
                os.remove(log)
            srv = subprocess.Popen([sys.executable, os.path.join(REPO, "tests", "fake_sse.py"), os.path.join(w, "s.json"), "--ctx", ctx, "--log", log],
                                   stdout=subprocess.PIPE)
            try:
                port = srv.stdout.readline().decode().strip()
                run_awl(awl, session, pr, f"http://127.0.0.1:{port}", {"AWL_KEY": "dry", "AWL_MODEL": "fake-model"}, timeout=120)
            finally:
                srv.kill()
            msgs = json.loads(open(log).readline())["messages"]
            out.append(" ".join(m.get("content") or "" for m in msgs[1:] if not (m.get("content") or "").startswith("[Context reset:")) +
                       " ".join(c["function"]["arguments"] for m in msgs for c in m.get("tool_calls") or []))
    finally:
        shutil.rmtree(w, ignore_errors=True)
    return out


def main():
    session, qfile = sys.argv[1], sys.argv[2]
    ctx = arg("--ctx", "16000")
    modes = arg("--modes", "retrieval,summary").split(",")
    reps = int(arg("--reps", "1"))
    upstream = arg("--upstream", "http://127.0.0.1:12434")
    qs = json.load(open(qfile))
    awl = os.path.abspath(os.environ.get("AWL_BIN", os.path.join(REPO, "zig-out/bin/awl")))
    out = os.path.join(ROOT, "results", "recall-" + time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(os.path.join(out, "proxy"))
    pargs = []
    model = arg("--model", "")
    if upstream == "openrouter":
        upstream = "https://openrouter.ai/api"
        model = model or "deepseek/deepseek-v4.1-flash"
        pargs = ["--model", model, "--ctx", ctx, "--budget", arg("--budget", "1.00")]
        pargs += ["--key-file", OR_KEY] if os.path.exists(OR_KEY) else []
    prompts = [q["q"] + " Answer with the exact text from the earlier work, quoted." for q in qs]
    dry = kept(awl, session, prompts, ctx)
    leaks = [norm(q["a"]) in norm(d) for q, d in zip(qs, dry)]
    print(f"dry run: {sum(leaks)} of {len(qs)} answers still in context after the reset (not scored)", flush=True)
    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "proxy.py"), "--upstream", upstream, "--out", os.path.join(out, "proxy")] + pargs,
                             stdout=subprocess.PIPE)
    rows = []
    try:
        base = f"http://127.0.0.1:{proxy.stdout.readline().decode().strip()}"
        if not model:
            model = json.loads(subprocess.run(["curl", "-s", base + "/v1/models"], capture_output=True, text=True).stdout)["data"][0]["id"]
        gk = os.path.expanduser("~/.local/state/omarchy/local-ai/gateway.key")
        key = os.environ.get("AWL_KEY") or (open(gk).read().strip() if os.path.exists(gk) else "none")
        for rep in range(reps):
            for mode in modes:
                for i, q in enumerate(qs):
                    rid = f"{mode}-{i}-{rep}"
                    with open(os.path.join(out, "proxy", rid + ".ctx"), "w") as f:
                        f.write(f"{model}\n{ctx}\n")
                    extra = {"AWL_KEY": key, "AWL_MODEL": model}
                    if mode == "summary":
                        extra["AWL_COMPACT"] = "summary"
                    p, wall = run_awl(awl, session, prompts[i], f"{base}/run/{rid}", extra)
                    pf = os.path.join(out, "proxy", rid + ".jsonl")
                    reqs = [json.loads(l) for l in open(pf)] if os.path.exists(pf) else []
                    leak = leaks[i]
                    hit = norm(q["a"]) in norm(p.stdout)
                    rows.append({"mode": mode, "q": i, "rep": rep, "hit": hit, "leak": leak, "wall_s": round(wall, 1), "requests": len(reqs),
                                 "prompt": sum(r.get("prompt_tokens", 0) or 0 for r in reqs), "completion": sum(r.get("completion_tokens", 0) or 0 for r in reqs),
                                 "cost": sum(r.get("cost", 0) or 0 for r in reqs), "reply": p.stdout.strip()[-300:], "rc": p.returncode})
                    print(f"{mode:9} q{i:<2} {'HIT ' if hit else 'miss'}{' leak' if leak else ''}  {wall:6.1f} s  {rows[-1]['requests']} req", flush=True)
    finally:
        proxy.kill()
    with open(os.path.join(out, "rows.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(f"\nwindow {ctx} tokens, model {model}, {len(qs)} questions x {reps}; rows in {out}/rows.jsonl")
    print(f"{'mode':10} {'recall':>8} {'leaks':>6} {'wall s':>8} {'req':>5} {'prompt tok':>11} {'compl tok':>10} {'cost $':>8}")
    for mode in modes:
        rs = [r for r in rows if r["mode"] == mode]
        sc = [r for r in rs if not r["leak"]]
        print(f"{mode:10} {sum(r['hit'] for r in sc):>3}/{len(sc):<4} {len(rs) - len(sc):>6} {sum(r['wall_s'] for r in rs) / max(len(rs), 1):>8.1f} "
              f"{sum(r['requests'] for r in rs) / max(len(rs), 1):>5.1f} {sum(r['prompt'] for r in rs) // max(len(rs), 1):>11} "
              f"{sum(r['completion'] for r in rs) // max(len(rs), 1):>10} {sum(r['cost'] for r in rs):>8.4f}")


if __name__ == "__main__":
    main()
