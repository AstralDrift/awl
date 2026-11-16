# Tool calls per reply on Terminal-Bench 2, awl vs pi (2026-11-02)

Question: does awl make fewer or more tool calls per model reply than pi on the 10-28 Terminal-Bench 2 runs?

Source: the proxy logs in `arena/results/tb/proxy/` (gitignored, not in the repo). One record per model request; `tool_calls` is an integer count. Only records whose `path` ends in `completions` are counted (that is all of them, every one status 200). Dates are local time (CST).

## The 20-task run (2026-10-28 night, LOG row "Terminal-Bench 2.0, 20-task subset")

Each run crosses midnight, so these rows pool all of a log's records.

| log | replies | mean calls | 0 | 1 | 2 | 3+ |
|---|---|---|---|---|---|---|
| awl-ctl (control) | 378 | 1.02 | 5.3% | 89.4% | 5.0% | 0.3% |
| pi-ctl (control) | 399 | 1.04 | 5.0% | 88.2% | 5.8% | 1.0% |
| awl-p208 | 422 | 1.02 | 4.5% | 88.9% | 6.4% | 0.2% |
| pi-p208 | 338 | 1.04 | 5.3% | 87.0% | 7.1% | 0.6% |

Both harnesses make one tool call in about 88–89% of replies, and both average about 1.0 calls per reply. pi is slightly more often at 2 or more calls (6.8% / 7.7% vs awl's 5.3% / 6.6%). At this sample size the gap is noise. Neither harness gets the model to batch tool calls.

## `awl.jsonl` / `pi.jsonl` by local date

| harness | date | replies | mean calls | 0 | 1 | 2 | 3+ |
|---|---|---|---|---|---|---|---|
| awl | 2026-10-23 | 598 | 1.09 | 4.5% | 84.3% | 9.5% | 1.7% |
| awl | 2026-10-27 | 177 | 0.89 | 12.4% | 85.9% | 1.7% | 0.0% |
| awl | 2026-10-28 | 46 | 0.96 | 8.7% | 87.0% | 4.3% | 0.0% |
| pi | 2026-10-23 | 408 | 1.03 | 4.9% | 87.7% | 6.6% | 0.7% |
| pi | 2026-10-27 | 77 | 0.96 | 9.1% | 85.7% | 5.2% | 0.0% |
| pi | 2026-10-28 | 60 | 0.97 | 6.7% | 90.0% | 3.3% | 0.0% |

The 10-28 rows here are not the 20-task run. They cover about five minutes each (awl 08:02–08:07, pi 08:07–08:13), which matches the morning `--smoke` cache check (LOG row "Why awl misses cobol-modernization"). The 10-27 rows are the daytime `--dev` runs.

## Script

```sh
cd arena/results/tb/proxy && python3 -c "
import json,collections,datetime as D
for h in ['awl','pi','awl-ctl','pi-ctl','awl-p208','pi-p208']:
    g=collections.defaultdict(list)
    for l in open(h+'.jsonl'):
        r=json.loads(l)
        if r['path'].endswith('completions'):
            g[D.datetime.fromtimestamp(r['t0']).date()].append(int(r['tool_calls']))
    for d,v in sorted(g.items()):
        n=len(v); print(h,d,n,round(sum(v)/n,2),*[round(100*sum(map(f,v))/n,1) for f in (lambda x:x==0,lambda x:x==1,lambda x:x==2,lambda x:x>=3)])
"
```
