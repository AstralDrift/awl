# Less, but better: four things that ship on a Keep with no measurement (2026-11-01)

An audit of the harness against six rules (turn failures into rules, delete rules that don't
help, keep instructions short, fewer sharper tools, back rules with scripts, prune regularly)
found the dev loop in order and four model-facing pieces that shipped without an arena row
showing they help. Each gets one A/B on the desktop; the arena decides. Nothing here is a
result: results go to arena/LOG.md, one row each.

Decision rule, the same as evolve.py's: two runs of the tune set per arm
(`flaky feature-cli refactor multifile server wrongfix`, from t3/t4), pooled. The lean arm wins
when it passes at least as many tasks and is not slower; a tie goes to the lean arm (it costs
tokens on every request). A single noisy failure decides nothing: rerun that task.

Build on the desktop, native, once per arm:

    zig build -Doptimize=ReleaseSmall && cp zig-out/bin/awl /tmp/awl-default
    zig build -Doptimize=ReleaseSmall -Dno_skills && cp zig-out/bin/awl /tmp/awl-no-skills
    zig build -Doptimize=ReleaseSmall -Dno_todo && cp zig-out/bin/awl /tmp/awl-no-todo

`arena/adapters/awl.sh` runs `$AWL_BIN`, so arms alternate by changing one variable. Run the
arms interleaved (A, B, A, B), not two of one then two of the other: the engine's state drifts.

## 1. Skills index (`-Dno_skills`)

Shipped 2026-10-21 with the pstack adoption (LOG line 24: "Next: live check that the model loads
playbooks"). Cost: ~626 tokens of index on every request. Evidence so far: a first-turn A/B on
minimax showed no prompt effect (LOG, T4 plumbing row); the Jelly Blobs skill changed nothing in
the model's method (LOG 2026-10-27). The `skills/` folder itself stays in the repo either way:
users may want it. The question is whether the index is on by default.

    T=flaky,feature-cli,refactor,multifile,server,wrongfix     # the tier only sets defaults; evolve.py runs this mix under t3
    AWL_BIN=/tmp/awl-default   arena/run.py t3 --h awl --tasks $T --repeat 1
    AWL_BIN=/tmp/awl-no-skills arena/run.py t3 --h awl --tasks $T --repeat 1
    (then the same two lines again: two runs per arm, interleaved)

Also count how often a run opened a SKILL.md at all: an index nobody reads is pure cost. The
proxy keeps each run's newest request, the whole history, in `<run>.last.json` (old tool
outputs may be elided by then; the calls stay).

    grep -l 'SKILL.md' arena/results/<ts>/proxy/*.last.json | wc -l

## 2. The todo tool (`-Dno_todo`)

Shipped in the same bundle. The only signal since: longsession's turns rose from ~8.7 to ~10
once the checklist appeared (LOG 2026-10-21, regression check). It is also what the TUI pins as
the live checklist, so a cut changes the UI too: with no todo tool the pinned checklist is empty.
Same commands as 1 with `/tmp/awl-no-todo`. Measure turns and wall time, not only passes.

## 3. The two think caps (`AWL_THINK_MAX`, `AWL_THINK_BUDGET`)

Both opt-in, both unmeasured on the tune set. `AWL_THINK_MAX` cut one run's first think from
~16 min to ~3 min (LOG 2026-10-27, "next: measure it on the tune set for pass rate").
`AWL_THINK_BUDGET` is SGLang's custom parameter, only meaningful with
`--enable-strict-thinking`, which the desktop's engine runs. No build needed: run.py starts
the adapter with the caller's environment, and arena/adapters/awl.sh execs awl with it.

    AWL_THINK_MAX=8192    arena/run.py t3 --h awl --tasks $T --repeat 1   (vs unset)
    AWL_THINK_BUDGET=8192 arena/run.py t3 --h awl --tasks $T --repeat 1   (vs unset, SGLang strict thinking on)

Outcome per knob: keep as opt-in (it helped), make it the default (it helped a lot and hurt
nothing), or delete it (no effect). Nothing in between: no folding into another variable.

## 4. The loop detector

Shipped 2026-10-27, fired 0 times in the one long run that could have used it (gummy bears).
No build, no run: count its note in the newest request of every arena run since daf6296 (a
note in an output elided before the run's end is missed, so this undercounts; the gummy bears
run's count of 0 came from the live session).

    grep -l 'you have made this exact call' arena/results/*/proxy/*.last.json | wc -l

Zero fires over the next two weeks of runs: delete it (agent.zig `repeats`, ~40 lines, and the
e2e check). Fires that preceded a recovery: keep, and say so in a LOG row.

## When the decisions land

- Remove `-Dno_skills` and `-Dno_todo` from build.zig and their two comptime gates
  (tools.zig `with_todo`, agent.zig). They exist for these runs only.
- Edit LOG lines 24 and 71: replace "next: ..." with what was measured and the row that did it.
  `zig build lint` fails a row whose decision still says "next:" after 14 days: line 24 from
  2026-11-05, line 71 from 2026-11-11. Two older promises outside this audit are in the same
  queue: line 45 (cut awl's requests per task) from 2026-11-07 and line 78 (3x night runs on
  Terminal-Bench) from 2026-11-12.
