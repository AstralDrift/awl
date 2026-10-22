---
name: playbook-bug-fix
description: Steps for fixing a reported bug, failing test, crash or wrong output. Use for any "X is broken / wrong / failing" task.
---

# Bug fix

Load these steps into the todo tool first. A step you skip stays in the list as `skip: <reason>`.

1. Reproduce. Run the failing test, command or example and keep its exact output. If it will not reproduce, narrow the conditions until it does.
2. Find the root cause. Form hypotheses, rule them out with real evidence (run code, print values, read the actual source). Trace the symptom back to the first place the state goes wrong.
3. Write the failing check first when a cheap one exists (a test, or a one-line command). Confirm it fails for the right reason.
4. Fix at the root, with the smallest change the evidence supports. A guard that only hides the symptom is not a fix.
5. Prove it. Rerun the step 1 reproduction and the step 3 check, plus the project's test suite. Show the before and after output.
6. Report: what was broken, the root cause, the fix, and the proof.

After two failed fixes that share one assumption, stop. Write the assumption down and test it directly before a third fix.
