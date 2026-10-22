#!/usr/bin/env python3
"""Progress of the newest (or given) arena run: done/total, passes, spend, what's running now.

  arena/status.py [results.jsonl] [--total N]
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
files = [a for a in sys.argv[1:] if a.endswith(".jsonl")]
path = files[0] if files else max(glob.glob(os.path.join(ROOT, "results", "*.jsonl")))
rows = [json.loads(l) for l in open(path)]
meta = next((r for r in rows if r.get("meta")), {})
rows = [r for r in rows if not r.get("meta")]
total = int(sys.argv[sys.argv.index("--total") + 1]) if "--total" in sys.argv else meta.get("total", 0)
outdir = path[:-6]
spent = sum(json.loads(l).get("cost", 0) or 0 for f in glob.glob(os.path.join(outdir, "proxy", "*.jsonl")) for l in open(f))
alive = subprocess.run(["pgrep", "-f", "arena/run.py"], capture_output=True).returncode == 0
logs = sorted(glob.glob(os.path.join(outdir, "logs", "*.log")), key=os.path.getmtime)
done_ids = {f"{r['harness']}-{r['task']}-{r['rep']}" for r in rows}
current = next((os.path.basename(l)[:-4] for l in reversed(logs) if os.path.basename(l)[:-4] not in done_ids), None)
print(f"{os.path.basename(path)}  {meta.get('model', '?')}  {'RUNNING' if alive else 'not running'}")
print(f"done {len(rows)}/{total or '?'}  left {total - len(rows) if total else '?'}  "
      f"pass {sum(r['success'] for r in rows)}  fail {sum(not r['success'] for r in rows)}  "
      f"spent ${spent:.3f}" + (f" of ${meta['budget']:.2f}" if meta.get("budget") else ""))
if alive and current:
    print(f"now: {current}")
for r in rows:
    if not r["success"]:
        print(f"  fail {r['harness']:5} {r['task']:12} rep {r['rep']}  {r.get('why', '')[:90]}")
