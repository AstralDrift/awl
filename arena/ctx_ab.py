#!/usr/bin/env python3
"""Context-strategy A/B table: one row per harness (awl = compact, awl-fresh, awl-async).

  arena/ctx_ab.py results/A.jsonl [results/B.jsonl ...] [--tasks a,b | --exclude a,b] [--engine CONTAINER] [--runs]

Per mode, over every run in the given results files: pass, recall (task probe.sh passed, over runs that
have one), mean wall s, mean prompt tokens split cached/uncached, completion tokens, turns (requests),
retrievals (tool calls that read the session view or session files), resets (compactions, fresh
contexts, swapped summaries, from the run log) and, for async, background summaries started/used/failed.
ttfb_s in the proxy log is a cache signal only while one request is in flight: with two, a hit waits in
the server's queue and looks like a miss.

Cached tokens: the proxy's cached_tokens when the upstream reports them (cloud). Local SGLang through the
Omarchy gateway does not, so they come from the engine's own log (`docker logs --timestamps`: each
"Prefill batch ... #new-token: N, #cached-token: M" line belongs to the newest request that started
before it). That is only right while nothing else uses the engine: a mismatch between the engine's
total and the proxy's prompt tokens of more than 5% is printed as a warning (expected when awl stopped a
reply mid-stream or killed a background summary: the proxy logs 0 tokens for those, the engine did the
work). --runs prints every run.
"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SESSIONS = os.path.expanduser("~/.local/state/awl-arena/awl/awl/sessions")
PREFILL = re.compile(r"^(\S+) .*Prefill batch.*#new-token: (\d+), #cached-token: (\d+)")
RESET = re.compile(r"compacted: |fresh context: |summary swapped in")
BG = {"started": "writing a summary in the background", "used": "summary swapped in", "failed": "the background summary (?:failed|is not done)"}


def arg(n, d):
    return sys.argv[sys.argv.index(n) + 1] if n in sys.argv else d


def engine_name():
    out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True).stdout.split()
    return next((n for n in out if n.endswith("-engine")), None)


def ts(s):  # docker's RFC 3339 with nanoseconds
    s = s.rstrip("Z")
    if "." in s:
        a, b = s.split(".")
        s = a + "." + b[:6]
    return datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).timestamp()


def prefills(container, since, until):
    if not container:
        return []
    p = subprocess.run(["docker", "logs", "--timestamps", "--since", str(int(since) - 2), "--until", str(int(until) + 5), container],
                       capture_output=True, text=True, errors="replace")
    out = []
    for line in (p.stdout + p.stderr).splitlines():
        m = PREFILL.match(line)
        if m:
            out.append((ts(m.group(1)), int(m.group(2)), int(m.group(3))))
    return sorted(out)


def session_of(wd, t_start, t_end):
    """This run's awl session file: its meta line names the workdir and it was written during the run."""
    for f in glob.glob(os.path.join(SESSIONS, "*.jsonl")):
        m = os.path.getmtime(f)
        if m < t_start - 5 or m > t_end + 60:
            continue
        with open(f, errors="replace") as fh:
            head = fh.readline()
        if json.dumps(wd)[1:-1] in head:
            return f
    return None


def retrievals(f):
    n = 0
    for line in open(f, errors="replace") if f else []:
        if not line.startswith('{"role":"assistant"'):
            continue
        try:
            calls = json.loads(line).get("tool_calls") or []
        except ValueError:
            continue
        n += sum(1 for c in calls if re.search(r"view-\d+\.txt|/sessions/|\.jsonl", c["function"].get("arguments", "")))
    return n


def main():
    files = [a for a in sys.argv[1:] if a.endswith(".jsonl")]
    container = arg("--engine", None) or engine_name()
    runs = []
    for path in files:
        rows = [json.loads(l) for l in open(path)]
        meta = next((r for r in rows if r.get("meta")), {})
        outdir = path[: -len(".jsonl")]
        hosted = "openrouter" in meta.get("upstream", "") or "x.ai" in meta.get("upstream", "")
        only, skip = arg("--tasks", ""), arg("--exclude", "")
        for r in rows:
            if r.get("meta") or (only and r["task"] not in only.split(",")) or (skip and r["task"] in skip.split(",")):
                continue
            rid = f"{r['harness']}-{r['task']}-{r['rep']}"
            pf = os.path.join(outdir, "proxy", rid + ".jsonl")
            reqs = [json.loads(l) for l in open(pf)] if os.path.exists(pf) else []
            r["cached"], r["uncached"], r["warn"] = r.get("cached_tokens", 0), r.get("prompt_tokens", 0) - r.get("cached_tokens", 0), ""
            if reqs and not hosted and not r.get("cached_tokens"):
                t0s = [q["t0"] for q in reqs]
                lines = prefills(container, t0s[0], reqs[-1]["t0"] + reqs[-1]["model_s"])
                new = cached = 0
                end = reqs[-1]["t0"] + reqs[-1]["model_s"]  # the next run starts right after: no slack here
                for t, n, c in lines:
                    if t0s[0] <= t <= end:
                        new += n
                        cached += c
                r["cached"], r["uncached"] = cached, new
                if r["prompt_tokens"] and abs(new + cached - r["prompt_tokens"]) > 0.05 * r["prompt_tokens"]:
                    r["warn"] = f"engine saw {new + cached} prompt tokens, proxy {r['prompt_tokens']}"
            log = os.path.join(outdir, "logs", rid + ".log")
            text = open(log, errors="replace").read() if os.path.exists(log) else ""
            r["resets"] = len(RESET.findall(text))
            r["bg"] = "/".join(str(len(re.findall(v, text))) for v in BG.values())  # async: background summaries started/used/failed
            wd = os.path.join("/tmp/awl-arena", meta.get("ts", ""), rid)  # run.py: SANDBOX/<ts>/<rid>
            r["retrievals"] = retrievals(session_of(wd, reqs[0]["t0"], reqs[-1]["t0"] + reqs[-1]["model_s"])) if reqs else 0
            runs.append(r)
    if "--runs" in sys.argv:
        for r in runs:
            print(f"{r['harness']:10} {r['task']:9} {r['rep']} {'PASS' if r['success'] else 'fail':4} probe={r.get('probe')} "
                  f"{r['wall_s']:7.1f}s turns={r['turns']:3} prompt={r['prompt_tokens']} cached={r['cached']} uncached={r['uncached']} "
                  f"compl={r['completion_tokens']} resets={r['resets']} bg={r['bg']} retr={r['retrievals']} {r['why'][:60]} {r['warn']}")
        print()
    print("| mode | runs | pass | recall | wall s | prompt tok cached / uncached | completion tok | turns | retrievals | resets | bg summaries started/used/failed |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for h in sorted({r["harness"] for r in runs}):
        rs = [r for r in runs if r["harness"] == h]
        n = len(rs)
        probes = [r["probe"] for r in rs if r.get("probe") is not None]
        mean = lambda k: sum(r[k] for r in rs) / n
        print(f"| {h} | {n} | {sum(r['success'] for r in rs)}/{n} | {sum(probes)}/{len(probes)} | {mean('wall_s'):.0f} | "
              f"{mean('cached') / 1000:.0f}K / {mean('uncached') / 1000:.0f}K | {mean('completion_tokens') / 1000:.1f}K | "
              f"{mean('turns'):.1f} | {mean('retrievals'):.1f} | {mean('resets'):.1f} | "
              + "/".join(str(sum(int(r["bg"].split("/")[k]) for r in rs)) for k in range(3)) + " |")
    for r in runs:
        if r["warn"]:
            print(f"warning: {r['harness']}-{r['task']}-{r['rep']}: {r['warn']}")


main()
