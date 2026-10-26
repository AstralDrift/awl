#!/usr/bin/env python3
"""Self-improvement loop for awl's harness (after Harness2's propose / probe / compose, with ground truth).

    arena/evolve.py init  NAME                          start from awl's built-in system prompt
    arena/evolve.py step  NAME [--steps N] [--tasks a,b] [--upstream URL] [--timeout S]
    arena/evolve.py heldout NAME [--upstream URL]       held-out tier (t5): best vs the starting prompt, never shown to the proposer
    arena/evolve.py show  NAME

What evolves: the system prompt (AWL_SYSTEM). One step:
  1. Evidence: the best prompt's latest arena results on the TUNE tasks (pass, wall time, turns, the end of each log).
  2. Propose: the model under test reads the prompt, the lessons so far and the evidence, and returns one edited prompt
     with a rationale. Proposals that name a task or a task file are rejected (lessons must be general).
  3. Probe: the candidate runs the tune tasks once. If it passes at least as many and is >= 5% faster in total, both
     run again, and it is adopted only if, over BOTH runs pooled, it passes at least as many and is >= 5% faster
     (one lucky run does not count; with 6 tasks a run, a single noisy failure should not decide either way).
     Rule history: until 2026-10-26 04:05 the rerun alone decided (pass count first); changed after step 1, whose
     decision (rejected) stands as recorded.
  4. Lessons: adopted and rejected edits go to lessons.md with their numbers; the proposer sees them next time.
The held-out tier is never used for decisions inside a step. State lives in arena/evolve/NAME/.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
TUNE = "flaky feature-cli refactor multifile server wrongfix".split()   # from t3/t4
HELD_OUT_TIER = "t5"
MAX_PROMPT = 2000


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def base_prompt():
    src = open(os.path.join(REPO, "src", "agent.zig")).read()
    body = src.split("const base_prompt =", 1)[1].split("\n;", 1)[0]
    return "\n".join(l.strip()[2:] for l in body.splitlines() if l.strip().startswith("\\\\"))


def state(name):
    d = os.path.join(ROOT, "evolve", name)
    os.makedirs(os.path.join(d, "cand"), exist_ok=True)
    return d


def log(d, rec):
    rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    with open(os.path.join(d, "log.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")


def save_prompt(d, text):
    h = hashlib.sha256(text.encode()).hexdigest()[:10]
    p = os.path.join(d, "cand", h + ".txt")
    open(p, "w").write(text)
    return p, h


def arena(prompt_file, tasks, tier, upstream, timeout, repeat=1):
    """Run awl on `tasks` with this system prompt; return the result rows and the run directory."""
    before = set(os.listdir(os.path.join(ROOT, "results")))
    env = dict(os.environ, AWL_SYSTEM=prompt_file)
    cmd = [sys.executable, os.path.join(ROOT, "run.py"), tier, "--h", "awl", "--tasks", ",".join(tasks),
           "--repeat", str(repeat), "--upstream", upstream, "--timeout", str(timeout)]
    subprocess.run(cmd, env=env, check=False)
    new = sorted(f for f in set(os.listdir(os.path.join(ROOT, "results"))) - before if f.endswith(".jsonl"))
    if not new:
        sys.exit("arena run produced no results")
    rows = [json.loads(l) for l in open(os.path.join(ROOT, "results", new[-1]))]
    return [r for r in rows if not r.get("meta")], os.path.join(ROOT, "results", new[-1][:-6])


def score(rows):
    return {"pass": sum(1 for r in rows if r["success"]), "n": len(rows), "wall": round(sum(r["wall_s"] for r in rows), 1),
            "turns": sum(r["turns"] for r in rows), "per_task": {r["task"]: [r["success"], round(r["wall_s"], 1), r["turns"]] for r in rows}}


def evidence(rows, rundir):
    out = []
    for r in rows:
        line = f"- {'PASS' if r['success'] else 'FAIL'} task {len(out) + 1}: {r['wall_s']:.0f} s, {r['turns']} turns, {r.get('completion_tokens', 0)} output tokens"
        if r.get("why"):
            line += f" ({r['why']})"
        out.append(line)
        lp = os.path.join(rundir, "logs", f"awl-{r['task']}-{r.get('rep', 0)}.log")
        if os.path.exists(lp) and (not r["success"] or r["turns"] >= 12):
            tail = open(lp, errors="replace").read()[-1800:]
            out.append("  end of that run's transcript:\n" + "\n".join("    " + l for l in tail.splitlines()[-30:]))
    return "\n".join(out)


def ask_model(upstream, model, messages):
    body = json.dumps({"model": model, "messages": messages, "max_tokens": 32768, "temperature": 0.7}).encode()
    req = urllib.request.Request(upstream + "/v1/chat/completions", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as f:
        return json.load(f)["choices"][0]["message"]["content"] or ""


def first_model(upstream):
    with urllib.request.urlopen(upstream + "/v1/models", timeout=10) as f:
        return json.load(f)["data"][0]["id"]


PROPOSER = """You improve the system prompt of awl, a terminal coding agent. The prompt below is sent to a coding model (you) at the start of every task; awl adds the date, the working directory and project notes after it.
Goal: more tasks solved, then less wall-clock time and fewer turns. Shorter prompts are better: every line costs tokens on every request.

Current prompt:
<prompt>
{prompt}
</prompt>

Lessons from earlier edits (adopted and rejected, with measured results):
{lessons}

Latest results of the current prompt on the tuning tasks:
{evidence}

Propose ONE change (add, rewrite or remove a line) that addresses a pattern you see in the evidence. It must be general advice for any coding task:
never mention specific tasks, file names, languages or test names. Keep the whole prompt under {maxlen} characters.
Answer with exactly:
<rationale>one or two sentences</rationale>
<prompt>the complete new prompt</prompt>"""


def propose(d, upstream, model, best, rows, rundir):
    lessons = open(os.path.join(d, "lessons.md")).read() if os.path.exists(os.path.join(d, "lessons.md")) else "(none yet)"
    msg = PROPOSER.format(prompt=best, lessons=lessons[-4000:], evidence=evidence(rows, rundir), maxlen=MAX_PROMPT)
    text = ask_model(upstream, model, [{"role": "user", "content": msg}])
    m, why = re.search(r"<prompt>\s*(.*?)\s*</prompt>", text, re.S), re.search(r"<rationale>\s*(.*?)\s*</rationale>", text, re.S)
    if not m:
        return None, "no <prompt> in the answer"
    cand = m.group(1).strip()
    # task names and task file names (with an extension) must not appear; generic words like "tests" may
    files = {f for t in TUNE for _, _, fs in os.walk(os.path.join(ROOT, "tasks", t, "setup")) for f in fs if "." in f}
    common = {"hello", "server", "rules", "rename", "issues", "ledger", "needle", "migrate", "flaky", "calc", "refactor",
              "README.md", "__init__.py", "__main__.py", "setup.py"}
    banned = (set(os.listdir(os.path.join(ROOT, "tasks"))) | files) - set(re.findall(r"[\w.-]+", base_prompt())) - common
    hit = [b for b in banned if len(b) > 3 and re.search(r"(?<![\w.-])" + re.escape(b) + r"(?![\w-])", cand)]
    if hit:
        return None, f"names task material {hit[:3]}"
    if len(cand) > MAX_PROMPT or cand == best:
        return None, "too long or unchanged"
    return (cand, why.group(1).strip() if why else ""), ""


def lesson(d, text):
    with open(os.path.join(d, "lessons.md"), "a") as f:
        f.write(text.rstrip() + "\n")


def pooled(a, b):
    return {"pass": a["pass"] + b["pass"], "n": a["n"] + b["n"], "wall": round(a["wall"] + b["wall"], 1)}


def better(c, b):
    return c["pass"] > b["pass"] or (c["pass"] == b["pass"] and c["wall"] <= 0.95 * b["wall"])


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, name = sys.argv[1], sys.argv[2]
    d = state(name)
    upstream = arg("--upstream", "http://127.0.0.1:30011")
    timeout = int(arg("--timeout", "900"))
    tasks = arg("--tasks", ",".join(TUNE)).split(",")
    best_p = os.path.join(d, "best.txt")
    if cmd == "init":
        if os.path.exists(best_p):
            sys.exit(f"{d} exists")
        open(best_p, "w").write(base_prompt())
        open(os.path.join(d, "start.txt"), "w").write(base_prompt())
        log(d, {"event": "init", "tasks": tasks})
        print("initialized", d)
    elif cmd == "step":
        model = first_model(upstream)
        for _ in range(int(arg("--steps", "1"))):
            best = open(best_p).read()
            last = os.path.join(d, "best_rows.json")
            if os.path.exists(last):
                rows, rundir = json.load(open(last))
            else:
                rows, rundir = arena(best_p, tasks, "t3", upstream, timeout)
                json.dump([rows, rundir], open(last, "w"))
                log(d, {"event": "measure-best", "score": score(rows)})
            got, err = propose(d, upstream, model, best, rows, rundir)
            if not got:
                log(d, {"event": "proposal-rejected", "why": err})
                print("proposal rejected:", err)
                continue
            cand, why = got
            cp, h = save_prompt(d, cand)
            crows, crun = arena(cp, tasks, "t3", upstream, timeout)
            cs, bs = score(crows), score(rows)
            rec = {"event": "probe", "cand": h, "rationale": why, "cand_score": cs, "best_score": bs}
            if better(cs, bs):  # confirm with a fresh paired rerun of both
                rows2, run2 = arena(best_p, tasks, "t3", upstream, timeout)
                crows2, crun2 = arena(cp, tasks, "t3", upstream, timeout)
                cs2, bs2 = score(crows2), score(rows2)
                pc, pb = pooled(cs, cs2), pooled(bs, bs2)
                rec.update(confirm_cand=cs2, confirm_best=bs2, pooled_cand=pc, pooled_best=pb, adopted=better(pc, pb))
                if rec["adopted"]:
                    open(best_p, "w").write(cand)
                    json.dump([crows2, crun2], open(last, "w"))
                    lesson(d, f"- ADOPTED ({why}) pass {bs['pass']}->{cs['pass']} and {bs2['pass']}->{cs2['pass']}, wall {bs['wall']}->{cs['wall']} s and {bs2['wall']}->{cs2['wall']} s")
                else:
                    json.dump([rows2, run2], open(last, "w"))
                    lesson(d, f"- rejected on the rerun ({why}): first pass {bs['pass']}->{cs['pass']} wall {bs['wall']}->{cs['wall']} s; rerun {bs2['pass']}->{cs2['pass']} wall {bs2['wall']}->{cs2['wall']} s")
            else:
                rec["adopted"] = False
                lesson(d, f"- rejected ({why}): pass {bs['pass']}->{cs['pass']}, wall {bs['wall']}->{cs['wall']} s")
            log(d, rec)
            print(json.dumps(rec, indent=1)[:1500])
    elif cmd == "heldout":
        tiers = open(os.path.join(ROOT, "tiers.txt")).read()
        ho = [l.split(":", 1)[1].split() for l in tiers.splitlines() if l.startswith(HELD_OUT_TIER + ":")][0]
        res = {}
        for label, p in (("start", os.path.join(d, "start.txt")), ("best", best_p)):
            rows, _ = arena(p, ho, HELD_OUT_TIER, upstream, int(arg("--timeout", "1500")))
            res[label] = score(rows)
        log(d, {"event": "heldout", **res})
        print(json.dumps(res, indent=1))
    elif cmd == "show":
        print(open(best_p).read(), "\n---")
        for l in open(os.path.join(d, "log.jsonl")):
            r = json.loads(l)
            print(r["ts"], r["event"], {k: v for k, v in r.items() if k in ("adopted", "why", "rationale")},
                  {k: (v["pass"], v["wall"]) for k, v in r.items() if isinstance(v, dict) and "pass" in v})
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
