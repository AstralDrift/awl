A/B test: does telling the model to batch independent tool calls make awl faster on Terminal-Bench 2 without losing tasks?

Background: on the 10-28 TB2 run, awl and pi both average ~1.0 tool calls per reply (arena/notes/2026-11-02-tb-tool-calls.md, PR #22), so every tool call costs a full model round trip.

1. Add one sentence to awl's system prompt, behind an env var (AWL_BATCH=1, off by default) so one binary serves both arms. Something like: "When several tool calls do not depend on each other's results (reading several files, independent searches), make them all in one reply." Do not change anything else.
2. Run arena/tb.sh awl on the 20-task subset twice per arm, default vs AWL_BATCH=1, same settings as the 10-28 night run. Run the arms back to back on an idle engine, and keep each arm's proxy log and jobs separate. (Quick read first if you like: --dev plus --smoke, ~10 min per arm.)
3. Report per arm: tasks passed, timeouts, wall time, model requests, tool calls per reply, prompt and completion tokens. Use arena/tb_report.py and the calls-per-reply script in the tool-calls note.
4. Add one row to arena/LOG.md with the hypothesis, the change, the result and a decision. Run-to-run spread is about ±2 tasks at n=20, so call it a win only if calls per reply goes up, requests and wall time go down, and the pass count doesn't drop. Otherwise revert the prompt change and keep only the LOG row.
5. Commit to this branch (tb-batch-ab) and push it. Don't merge.

## Overnight run (step 2, about 5 hours on the local engine)

Smoke done on 2026-11-02 (LOG row of that date). The full runs, arms in A B B A order so drift hits both:

```sh
for a in default batch batch default; do
  if [ $a = batch ]; then AWL_BATCH=1 arena/tb.sh awl $(arena/tb.sh --subset)
  else env -u AWL_BATCH arena/tb.sh awl $(arena/tb.sh --subset); fi
done
arena/tb_report.py $(ls arena/results/tb/jobs | grep -E '^awl(-batch)?-MMDD-')   # tonight's four jobs
```

Calls per reply per job: the script in arena/notes/2026-11-02-tb-tool-calls.md, limited to each job's time window.

