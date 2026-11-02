#!/usr/bin/env python3
"""Arena runner: same model, same tasks, different harnesses.

  arena/run.py t0                       # awl only, no GPU: budgets + e2e (seconds)
  arena/run.py t1 [--h "awl pi" | --h all] [--repeat 1]   # default awl vs pi; all = + omp grok
  arena/run.py t2 [--h ...] [--repeat 2] [--timeout 300] [--tasks a,b]
  arena/run.py t3 [...]                 # real coding/build tasks, 600 s timeout
  arena/run.py t4 [...]                 # long-horizon tasks (server, big log, migration, wrong fix, rules)
  arena/run.py t5 [...]                 # 40-100 steps in a small window: 8 issues, 40-file API move, spec implementation
  arena/run.py t3 --upstream openrouter [--model deepseek/deepseek-v4.1-flash] [--provider P] [--budget 1.50]

--upstream openrouter reads the key from ~/.local/state/awl-arena/openrouter.key (or
OPENROUTER_API_KEY). --budget (USD, default 1.50 there) stops starting new runs once the
proxy-recorded OpenRouter cost reaches it. Task workdirs live in /tmp/awl-arena/<ts>/, outside the
repo and home, so no harness picks up an unrelated AGENTS.md.

A task is tasks/<name>/{prompt.txt, setup/, check.sh, solve.sh} plus an optional setup.sh
(run in the fresh workdir) and hidden tests next to check.sh ($TASK points at the task dir).

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
SANDBOX = "/tmp/awl-arena"
OR_KEY = os.path.expanduser("~/.local/state/awl-arena/openrouter.key")
OR_MODEL = "deepseek/deepseek-v4.1-flash"
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


def check_openrouter_model(model):
    try:
        with urllib.request.urlopen("https://openrouter.ai/api/v1/models", timeout=20) as r:
            ids = {m["id"] for m in json.load(r)["data"]}
    except Exception as e:  # noqa: BLE001
        sys.exit(f"ARENA: cannot reach OpenRouter ({e})")
    if model not in ids:
        sys.exit(f"ARENA: OpenRouter has no model {model}")


def version(h):
    awl = [os.path.join(REPO, "zig-out/bin/awl"), "--version"]
    cmd = awl if h.startswith("awl") else [h, "--version"]
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


def tool_env():
    """PATH with the repo's mise zig first, so tasks build outside the repo."""
    env = dict(os.environ)
    try:
        z = subprocess.run(["mise", "where", "zig"], cwd=REPO, capture_output=True, text=True, timeout=20).stdout.strip()
        if z:
            env["PATH"] = z + os.pathsep + env["PATH"]
    except (OSError, subprocess.TimeoutExpired):
        pass
    env.setdefault("ARENA_CTX", "180224")
    return env


def spent(outdir):
    total = 0.0
    pdir = os.path.join(outdir, "proxy")
    for f in os.listdir(pdir) if os.path.isdir(pdir) else []:
        if f.endswith(".jsonl"):
            total += sum(json.loads(l).get("cost", 0) or 0 for l in open(os.path.join(pdir, f)))
    return total


def run_one(h, task, rep, base, model, timeout, outdir, wd_root, env0):
    rid = f"{h}-{task}-{rep}"
    wd = os.path.join(wd_root, rid)
    shutil.rmtree(wd, ignore_errors=True)
    tdir = os.path.join(ROOT, "tasks", task)
    shutil.copytree(os.path.join(tdir, "setup"), wd)
    env = dict(env0, SETUP=os.path.join(tdir, "setup"), TASK=tdir)
    # The window the harness is told: the task's own (forces compaction), and/or ARENA_CTX when set
    # explicitly (the smaller wins), so a context-strategy A/B can make every task overflow.
    wins = [int(open(os.path.join(tdir, "ctx")).read().strip())] if os.path.exists(os.path.join(tdir, "ctx")) else []
    wins += [int(os.environ["ARENA_CTX"])] if os.environ.get("ARENA_CTX") else []
    if wins:
        env["ARENA_CTX"] = str(min(wins))
        os.makedirs(os.path.join(outdir, "proxy"), exist_ok=True)  # the proxy answers /v1/models with it for this run
        with open(os.path.join(outdir, "proxy", rid + ".ctx"), "w") as f:
            f.write(f"{model}\n{env['ARENA_CTX']}\n")
    if os.path.exists(os.path.join(tdir, "setup.sh")):
        subprocess.run(["sh", os.path.join(tdir, "setup.sh")], cwd=wd, env=env, check=True, capture_output=True)
    prompt = os.path.join(ROOT, "tasks", task, "prompt.txt")
    log = open(os.path.join(outdir, "logs", rid + ".log"), "w")
    t0 = time.time()
    p = subprocess.Popen([os.path.join(ROOT, "adapters", h + ".sh"), wd, prompt, f"{base}/run/{rid}", model],
                         stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True, env=env)
    peak_tree = peak_main = 0
    timed_out = stalled = False
    while p.poll() is None:
        try:  # skip samples taken before the adapter script has exec'd the harness
            wrapper = open(f"/proc/{p.pid}/comm").read().strip().endswith(".sh")
        except OSError:
            wrapper = True
        if not wrapper:
            t, m = tree_rss(p.pid)
            peak_tree, peak_main = max(peak_tree, t), max(peak_main, m)
        # stall watchdog: no first request in 120 s, or none for 300 s -> stop now, not at the timeout
        # activity = a finished request (.jsonl) or bytes streaming in (.active heartbeat from the proxy)
        acts = [os.path.getmtime(f) for f in (os.path.join(outdir, "proxy", rid + ".jsonl"),
                                               os.path.join(outdir, "proxy", rid + ".active")) if os.path.exists(f)]
        idle = time.time() - (max(acts) if acts else t0)
        if idle > (300 if acts else 120):
            stalled = True
        if time.time() - t0 > timeout or stalled:
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
    ok, why = False, "stalled (no model request)" if stalled else "timeout"
    if not timed_out:
        try:
            c = subprocess.run(["sh", os.path.join(tdir, "check.sh")], cwd=wd, env=env, capture_output=True,
                               text=True, errors="replace", timeout=120)
            ok = c.returncode == 0
            why = "" if ok else ((c.stdout + c.stderr).strip().splitlines() or ["check failed"])[-1][:200]
        except subprocess.TimeoutExpired:
            why = "check timed out"
    probe = None  # a task's probe.sh checks one thing apart from the pass (recall: the exact detail was used)
    if os.path.exists(os.path.join(tdir, "probe.sh")):
        try:
            probe = subprocess.run(["sh", os.path.join(tdir, "probe.sh")], cwd=wd, env=env, capture_output=True, timeout=60).returncode == 0
        except subprocess.TimeoutExpired:
            probe = False
    reqs = []
    pf = os.path.join(outdir, "proxy", rid + ".jsonl")
    if os.path.exists(pf):
        reqs = [json.loads(l) for l in open(pf)]
    model_s = sum(r["model_s"] for r in reqs)
    return {
        "harness": h, "task": task, "rep": rep, "success": ok, "probe": probe, "why": why, "timed_out": timed_out, "exit": p.returncode,
        "wall_s": round(wall, 2), "model_s": round(model_s, 2), "harness_s": round(wall - model_s, 2),
        "turns": len(reqs), "tool_calls": sum(r["tool_calls"] for r in reqs),
        "prompt_tokens": sum(r["prompt_tokens"] for r in reqs),
        "completion_tokens": sum(r["completion_tokens"] for r in reqs),
        "cached_tokens": sum(r["cached_tokens"] for r in reqs),
        "bytes_sent": sum(r["bytes_sent"] for r in reqs),
        "first_prompt_bytes": reqs[0]["bytes_sent"] if reqs else 0,
        "peak_tree_kb": peak_tree, "peak_main_kb": peak_main,
        "cost": round(sum(r.get("cost", 0) or 0 for r in reqs), 5), "retries": sum(r.get("retries", 0) for r in reqs),
        "providers": sorted({r["provider"] for r in reqs if r.get("provider")}),
    }


def main():
    known = {"t0"} | {l.split(":")[0].strip() for l in open(os.path.join(ROOT, "tiers.txt")) if ":" in l}
    if len(sys.argv) < 2 or sys.argv[1] not in known:
        sys.exit(__doc__)
    tier = sys.argv[1]
    if tier == "t0":
        zig = ["mise", "exec", "--", "zig", "build"]
        rc = subprocess.run(zig + ["check", "e2e", "--summary", "none"], cwd=REPO).returncode
        sys.exit(rc)
    # Default: awl vs pi, the closest rival (cheapest comparison). --h all for a full baseline per new tier.
    harnesses = arg("--h", "awl pi").split()
    if harnesses == ["all"]:
        harnesses = "awl pi omp grok".split()
    repeat = int(arg("--repeat", "1" if tier == "t1" else "2"))
    timeout = int(arg("--timeout", "1200" if tier == "t5" else "600" if tier in ("t3", "t4") else "300"))
    tasks = arg("--tasks", "").split(",") if "--tasks" in sys.argv else tier_tasks(tier)
    upstream = arg("--upstream", "http://127.0.0.1:12434")
    env0 = tool_env()
    pargs = []
    provider = arg("--provider", "")
    if upstream == "openrouter":
        key = OR_KEY if os.path.exists(OR_KEY) else ""
        if not key and not os.environ.get("OPENROUTER_API_KEY"):
            sys.exit(f"ARENA: no OpenRouter key. Save it to {OR_KEY} (chmod 600) or export OPENROUTER_API_KEY.")
        upstream = "https://openrouter.ai/api"
        model = arg("--model", OR_MODEL)
        check_openrouter_model(model)
        pargs = ["--model", model, "--ctx", env0["ARENA_CTX"]] + (["--key-file", key] if key else [])
        pargs += ["--provider", provider] if provider else []
        if "--keep-reasoning" in sys.argv:  # each harness sends its own reasoning setting
            pargs += ["--keep-reasoning-params"]
        budget = float(arg("--budget", "1.50"))
    else:
        model = arg("--model", None) or first_model(upstream)
        budget = float(arg("--budget", "0"))

    ts = time.strftime("%Y%m%d-%H%M%S") + f"-{int(time.time() * 1000) % 1000:03d}"
    outdir = os.path.join(ROOT, "results", ts)
    os.makedirs(os.path.join(outdir, "logs"))
    wd_root = os.path.join(SANDBOX, ts)
    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "proxy.py"), "--upstream", upstream,
                              "--out", os.path.join(outdir, "proxy")] + pargs, stdout=subprocess.PIPE)
    base = f"http://127.0.0.1:{proxy.stdout.readline().decode().strip()}"
    results = os.path.join(ROOT, "results", ts + ".jsonl")
    meta = {"meta": True, "tier": tier, "model": model, "ts": ts, "upstream": upstream, "provider": provider,
            "ctx": int(env0["ARENA_CTX"]), "budget": budget, "keep_reasoning": "--keep-reasoning" in sys.argv,
            "awl_reasoning": os.environ.get("AWL_REASONING", ""), "total": repeat * len(tasks) * len(harnesses), "versions": {h: version(h) for h in harnesses}}
    with open(results, "w") as f:
        f.write(json.dumps(meta) + "\n")
    print(f"arena {tier}: {len(tasks)} tasks x {len(harnesses)} harnesses x {repeat} on {model}")
    for k, v in meta["versions"].items():
        print(f"  {k}: {v}")
    stopped = False
    try:
        for rep in range(repeat):
            for task in tasks:
                for h in harnesses:
                    if budget and spent(outdir) >= budget:
                        stopped = True
                        break
                    r = run_one(h, task, rep, base, model, timeout, outdir, wd_root, env0)
                    with open(results, "a") as f:
                        f.write(json.dumps(r) + "\n")
                    print(f"  {'PASS' if r['success'] else 'fail'}  {h:5} {task:12} {r['wall_s']:6.1f}s  "
                          f"turns {r['turns']:2}  prompt {r['prompt_tokens']:7}  tree {r['peak_tree_kb'] / 1024:6.1f} MB"
                          + (f"  ({r['why']})" if r["why"] else ""),
                          flush=True)
                if stopped:
                    break
            if stopped:
                break
    finally:
        proxy.kill()
    if budget:
        print(f"spent ${spent(outdir):.3f} of ${budget:.2f} budget" + ("  (STOPPED: budget reached)" if stopped else ""))
    subprocess.run([sys.executable, os.path.join(ROOT, "report.py"), results])


if __name__ == "__main__":
    main()
