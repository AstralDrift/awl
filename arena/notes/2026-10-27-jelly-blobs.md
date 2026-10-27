# Jelly Blobs A/B (2026-10-27), Nanbeige4.3-33B live engine (3.0 bpw, fp4 KV 128K, Local AI gateway)

Prompt: one-file canvas soft-body toy (4 blobs, 16-point spring rings + area pressure, drag/throw, collisions,
Add/Reset buttons, count + bounce readout). One run per arm; awl -p, default steps.

| run | change | cap | result | tool calls | first reply thinking |
|---|---|---|---|---|---|
| B1 | none | 25 min | timeout; was debugging the sim blowing up in its own Node harness | 6 | 172K chars (~43K tokens, ~16 min) |
| A1 | web-ui-check skill | 45 min | timeout; found the root cause (rest area pi*r^2 vs the 16-gon's area) and was editing | 65 | 101K chars (~9 min) |
| T1 | skill + AWL_THINK_MAX=8192 | 45 min | timeout; still fighting pressure-vs-floor instability | 82 | 32K chars (cut; ~3 min) |

Findings
- The task is beyond this model in 45 min at ~45 tok/s: all three hit the same physics instability.
- The skill did not change the method: B1 also tested the physics in Node by itself; A1/T1 never opened a browser.
  No evidence of benefit -> not shipped (kept as arena/notes/candidates/web-ui-check-SKILL.md).
- AWL_THINK_MAX cut the first think from 9-16 min to ~3 min and gave more actions in the same time, with no visible
  harm; outcome unchanged (n=1). Stays opt-in until a task set shows pass rate holds.
