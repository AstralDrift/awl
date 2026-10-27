#!/usr/bin/env python3
"""Per-task table for Terminal-Bench jobs run by arena/tb.sh.

  arena/tb_report.py [JOB ...]   default: every job under results/tb/jobs with >= 10 trials

Pass/fail per task (T = agent timeout, E = other error) with agent seconds and completion
tokens (exact when trials ran one at a time, as --dev does), the score, wall time, and
model requests/tokens from the proxy log (records inside the job's time window;
agents run one at a time, so windows do not overlap).
"""
import json, os, sys
from datetime import datetime

TB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results/tb")
JOBS = os.path.join(TB, "jobs")


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def load(job):
    d = os.path.join(JOBS, job)
    trials, wins = {}, {}
    t0, t1 = 1e20, 0
    hin = hout = 0  # Harbor's own token counts (agents that report them)
    for t in os.listdir(d):
        f = os.path.join(d, t, "result.json")
        if not os.path.isfile(f):
            continue
        r = json.load(open(f))
        task = r.get("task_name") or t.split("__")[0]
        rew = ((r.get("verifier_result") or {}).get("rewards") or {}).get("reward") or 0
        exc = (r.get("exception_info") or {}).get("exception_type", "")
        mark = "pass" if rew >= 1 else ("T" if "Timeout" in exc else "E" if exc else "-")
        ae = r.get("agent_execution") or {}
        win = (ts(ae["started_at"]), ts(ae["finished_at"])) if ae.get("finished_at") else None
        trials[task] = mark
        wins[task] = win
        ar = r.get("agent_result") or {}
        hin += ar.get("n_input_tokens") or 0
        hout += ar.get("n_output_tokens") or 0
        t0, t1 = min(t0, ts(r["started_at"])), max(t1, ts(r["finished_at"]))
    agent = job.rsplit("-", 2)[0]
    reqs = []
    p = os.path.join(TB, "proxy", agent + ".jsonl")
    if os.path.exists(p):
        reqs = [x for x in map(json.loads, open(p)) if t0 <= x["t0"] <= t1]
    pin = sum(x["prompt_tokens"] for x in reqs)
    pout = sum(x["completion_tokens"] for x in reqs)
    if not pin:  # proxy before 2026-10-23 lost usage of non-streamed replies
        pin, pout = hin, hout
    cells = {}  # per task: mark, agent seconds, completion tokens (trials one at a time: windows are exact)
    for task, win in wins.items():
        if not win:
            cells[task] = trials[task]
            continue
        out = sum(x["completion_tokens"] for x in reqs if win[0] <= x["t0"] <= win[1])
        cells[task] = f"{trials[task]} {win[1] - win[0]:.0f}s {out / 1e3:.1f}K"
    return dict(job=job, agent=agent, trials=trials, cells=cells, secs=t1 - t0, reqs=reqs, pin=pin, pout=pout)


jobs = sys.argv[1:] or sorted(j for j in os.listdir(JOBS)
                              if len([t for t in os.listdir(os.path.join(JOBS, j)) if "__" in t]) >= 10)
rs = [load(j) for j in jobs]
tasks = sorted({t for r in rs for t in r["trials"]})
w = max(map(len, tasks))
print(" " * w + "".join(f" {r['agent'][:16]:>16}" for r in rs))
for t in tasks:
    print(t.ljust(w) + "".join(f" {r['cells'].get(t, ''):>16}" for r in rs))
print()
for r in rs:
    n, ok = len(r["trials"]), sum(v == "pass" for v in r["trials"].values())
    to = sum(v == "T" for v in r["trials"].values())
    q = r["reqs"]
    print(f"{r['job']:<32} {ok}/{n} pass  {to} timeouts  {r['secs'] / 60:.0f} min  {len(q)} requests  "
          f"{r['pin'] / 1e6:.1f}M prompt  {r['pout'] / 1e3:.0f}K completion")
