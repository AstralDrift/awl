#!/usr/bin/env python3
"""Arena runner: same model, same tasks, different harnesses.

  arena/run.py t0                       # awl only, no GPU: budgets + e2e (seconds)
  arena/run.py t1 [--h "awl pi omp grok"] [--repeat 1]
  arena/run.py t2 [--h ...] [--repeat 2] [--timeout 300] [--tasks a,b]

Every harness talks to the model through proxy.py. Results go to
arena/results/<ts>.jsonl (one row per harness x task x repeat), then report.py prints the table.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
PAGE = os.sysconf("SC_PAGE_SIZE")


def arg(name, default):
    a = sys.argv
    return a[a.index(name) + 1] if name in a else default


def tier_tasks(tier):
    for line in open(os.path.join(ROOT, "tiers.txt")):
        k, _, v = line.partition(":")
        if k.strip() == tier:
            return v.split()
    sys.exit(f"unknown tier {tier}")


def gateway_key():
    try:
        return open(os.path.expanduser("~/.local/state/omarchy/local-ai/gateway.key")).read().strip()
    except OSError:
        return ""


def first_model(upstream):
    req = urllib.request.Request(upstream + "/v1/models", headers={"Authorization": "Bearer " + gateway_key()})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.load(r)["data"][0]["id"]
    except Exception as e:  # noqa: BLE001 - any failure means "no model"
        sys.exit(f"ARENA: model server unreachable at {upstream} ({e}). Start a model in Omarchy Local AI first.")


def version(h):
    cmd = {"awl": [os.path.join(REPO, "zig-out/bin/awl"), "--version"]}.get(h, [h, "--version"])
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return (out.stdout or out.stderr).strip().splitlines()[0][:80]
    except Exception:  # noqa: BLE001
        return "unknown"


def tree_rss(root):
    """(total RSS of root and all descendants, RSS of root) in KB."""
    kids = {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open(f"/proc/{p}/stat") as f:
                s = f.read()
            ppid = int(s[s.rindex(")") + 2:].split()[1])
            kids.setdefault(ppid, []).append(int(p))
        except (OSError, ValueError):
            pass
    total, main, stack = 0, 0, [root]
    while stack:
        pid = stack.pop()
        try:
            with open(f"/proc/{pid}/statm") as f:
                kb = int(f.read().split()[1]) * PAGE // 1024
        except (OSError, ValueError, IndexError):
            kb = 0
        total += kb
        if pid == root:
            main = kb
        stack.extend(kids.get(pid, []))
    return total, main


def run_one(h, task, rep, base, model, timeout, outdir):
    rid = f"{h}-{task}-{rep}"
    wd = os.path.join(outdir, "runs", rid)
    shutil.rmtree(wd, ignore_errors=True)
    shutil.copytree(os.path.join(ROOT, "tasks", task, "setup"), wd)
    prompt = os.path.join(ROOT, "tasks", task, "prompt.txt")
    log = open(os.path.join(outdir, "logs", rid + ".log"), "w")
    t0 = time.time()
    p = subprocess.Popen([os.path.join(ROOT, "adapters", h + ".sh"), wd, prompt, f"{base}/run/{rid}", model],
                         stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
    peak_tree = peak_main = 0
    timed_out = False
    while p.poll() is None:
        try:  # skip samples taken before the adapter script has exec'd the harness
            wrapper = open(f"/proc/{p.pid}/comm").read().strip().endswith(".sh")
        except OSError:
            wrapper = True
        if not wrapper:
            t, m = tree_rss(p.pid)
            peak_tree, peak_main = max(peak_tree, t), max(peak_main, m)
        if time.time() - t0 > timeout:
            timed_out = True
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            break
        time.sleep(0.02)
    wall = time.time() - t0
    try:
        os.killpg(p.pid, signal.SIGKILL)  # stray children
    except ProcessLookupError:
        pass
    env = dict(os.environ, SETUP=os.path.join(ROOT, "tasks", task, "setup"))
    ok = not timed_out and subprocess.run(["sh", os.path.join(ROOT, "tasks", task, "check.sh")], cwd=wd, env=env,
                                          capture_output=True, timeout=30).returncode == 0
    reqs = []
    pf = os.path.join(outdir, "proxy", rid + ".jsonl")
    if os.path.exists(pf):
        reqs = [json.loads(l) for l in open(pf)]
    model_s = sum(r["model_s"] for r in reqs)
    return {
        "harness": h, "task": task, "rep": rep, "success": ok, "timed_out": timed_out, "exit": p.returncode,
        "wall_s": round(wall, 2), "model_s": round(model_s, 2), "harness_s": round(wall - model_s, 2),
        "turns": len(reqs), "tool_calls": sum(r["tool_calls"] for r in reqs),
        "prompt_tokens": sum(r["prompt_tokens"] for r in reqs),
        "completion_tokens": sum(r["completion_tokens"] for r in reqs),
        "cached_tokens": sum(r["cached_tokens"] for r in reqs),
        "bytes_sent": sum(r["bytes_sent"] for r in reqs),
        "first_prompt_bytes": reqs[0]["bytes_sent"] if reqs else 0,
        "peak_tree_kb": peak_tree, "peak_main_kb": peak_main,
    }


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("t0", "t1", "t2"):
        sys.exit(__doc__)
    tier = sys.argv[1]
    if tier == "t0":
        zig = ["mise", "exec", "--", "zig", "build"]
        rc = subprocess.run(zig + ["check", "e2e", "--summary", "none"], cwd=REPO).returncode
        sys.exit(rc)
    harnesses = arg("--h", "awl pi omp grok").split()
    repeat = int(arg("--repeat", "1" if tier == "t1" else "2"))
    timeout = int(arg("--timeout", "300"))
    tasks = arg("--tasks", "").split(",") if "--tasks" in sys.argv else tier_tasks(tier)
    upstream = arg("--upstream", "http://127.0.0.1:12434")
    model = arg("--model", None) or first_model(upstream)

    ts = time.strftime("%Y%m%d-%H%M%S") + f"-{int(time.time() * 1000) % 1000:03d}"
    outdir = os.path.join(ROOT, "results", ts)
    os.makedirs(os.path.join(outdir, "logs"))
    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "proxy.py"), "--upstream", upstream,
                              "--out", os.path.join(outdir, "proxy")], stdout=subprocess.PIPE)
    base = f"http://127.0.0.1:{proxy.stdout.readline().decode().strip()}"
    results = os.path.join(ROOT, "results", ts + ".jsonl")
    meta = {"meta": True, "tier": tier, "model": model, "ts": ts, "versions": {h: version(h) for h in harnesses}}
    with open(results, "w") as f:
        f.write(json.dumps(meta) + "\n")
    print(f"arena {tier}: {len(tasks)} tasks x {len(harnesses)} harnesses x {repeat} on {model}")
    for k, v in meta["versions"].items():
        print(f"  {k}: {v}")
    try:
        for rep in range(repeat):
            for task in tasks:
                for h in harnesses:
                    r = run_one(h, task, rep, base, model, timeout, outdir)
                    with open(results, "a") as f:
                        f.write(json.dumps(r) + "\n")
                    print(f"  {'PASS' if r['success'] else 'fail'}  {h:5} {task:11} {r['wall_s']:6.1f}s  "
                          f"turns {r['turns']:2}  prompt {r['prompt_tokens']:7}  tree {r['peak_tree_kb'] / 1024:6.1f} MB",
                          flush=True)
    finally:
        proxy.kill()
    subprocess.run([sys.executable, os.path.join(ROOT, "report.py"), results])


if __name__ == "__main__":
    main()
