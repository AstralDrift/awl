#!/usr/bin/env python3
"""Print the arena scoreboard for a results file (default: newest).

  arena/report.py [results.jsonl] [--accept]

--accept stores this run's per-harness medians as arena/baseline.json (t1/t2) or baseline-<tier>.json.
Medians use passing runs only (a timeout would otherwise dominate); pass is over all runs.
Deltas against the baseline are shown; a metric more than 10% worse is flagged.
"""
import glob
import json
import os
import statistics
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
files = [a for a in sys.argv[1:] if a.endswith(".jsonl")]
path = files[0] if files else max(glob.glob(os.path.join(ROOT, "results", "*.jsonl")))
rows = [json.loads(l) for l in open(path)]
meta = next((r for r in rows if r.get("meta")), {})
rows = [r for r in rows if not r.get("meta")]
color = sys.stdout.isatty()

# metric, label, format, lower-is-better
METRICS = [
    ("success", "pass", "{:.0%}", False),
    ("wall_s", "wall s", "{:.1f}", True),
    ("harness_s", "harness s", "{:.1f}", True),
    ("turns", "turns", "{:.0f}", True),
    ("prompt_tokens", "prompt tok", "{:.0f}", True),
    ("completion_tokens", "compl tok", "{:.0f}", True),
    ("first_prompt_bytes", "1st req B", "{:.0f}", True),
    ("peak_main_kb", "main MB", "{:.1f}", True),
    ("peak_tree_kb", "tree MB", "{:.1f}", True),
    ("cost", "cost $", "{:.4f}", True),
]


def summarize(rs):
    out = {}
    ok = [r for r in rs if r["success"]] or rs
    for k, *_ in METRICS:
        vals = [float(r.get(k, 0) or 0) for r in (rs if k == "success" else ok)]
        out[k] = sum(vals) / len(vals) if k == "success" else statistics.median(vals)
    return out


harnesses = list(dict.fromkeys(r["harness"] for r in rows))
summary = {h: summarize([r for r in rows if r["harness"] == h]) for h in harnesses}
tier = meta.get("tier", "t2")
hosted = meta.get("upstream", "").startswith("https")
if hosted:  # one baseline per hosted model, never mixed with the local Qwen numbers
    bpath = os.path.join(ROOT, f"baseline-{tier}-{meta.get('model', '?').split('/')[-1]}.json")
else:
    bpath = os.path.join(ROOT, "baseline.json" if tier in ("t1", "t2") else f"baseline-{tier}.json")
base = json.load(open(bpath)) if os.path.exists(bpath) else {}

print(f"\n{meta.get('tier', '?')} on {meta.get('model', '?')} — {os.path.basename(path)} (medians; pass = rate)")
hdr = f"{'harness':8}" + "".join(f"{lab:>12}" for _, lab, _, _ in METRICS)
print(hdr)
print("-" * len(hdr))
for h in harnesses:
    line = f"{h:8}"
    for k, _, fmt, lower in METRICS:
        v = summary[h][k]
        shown = v / 1024 if k.endswith("_kb") else v
        cell = fmt.format(shown)
        b = base.get(h, {}).get(k)
        flag = ""
        if b:
            worse = (v - b) / b if lower else (b - v) / b
            if worse > 0.10:
                flag = "!"
        cell += flag
        if flag and color:
            cell = f"\x1b[31m{cell:>12}\x1b[0m"
            line += cell
        else:
            line += f"{cell:>12}"
    print(line)

tasks = list(dict.fromkeys(r["task"] for r in rows))
print("\nper task (passes / runs)")
print(f"{'task':12}" + "".join(f"{h:>8}" for h in harnesses))
for t in tasks:
    cells = []
    for h in harnesses:
        rs = [r for r in rows if r["task"] == t and r["harness"] == h]
        cells.append(f"{sum(r['success'] for r in rs)}/{len(rs)}")
    print(f"{t:12}" + "".join(f"{c:>8}" for c in cells))
if any(r.get("cost") for r in rows):
    print(f"\ntotal cost ${sum(r.get('cost', 0) or 0 for r in rows):.3f}, rate-limit retries {sum(r.get('retries', 0) for r in rows)}")
    from collections import Counter
    print("providers per run:", dict(Counter(",".join(r.get("providers", [])) or "?" for r in rows)))
fails = [r for r in rows if not r["success"]]
if fails:
    print("\nfailures")
    for r in fails:
        print(f"  {r['harness']:5} {r['task']:12} rep {r['rep']}  {r.get('why') or ('timeout' if r['timed_out'] else '?')}")
print("\nmain MB = harness process only; tree MB = harness + its children (tools, workers). ! = >10% worse than baseline.")

if "--accept" in sys.argv:
    base.update(summary)
    json.dump(base, open(bpath, "w"), indent=1)
    print(f"baseline updated: {', '.join(harnesses)}")
