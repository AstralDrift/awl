---
name: playbook-feature
description: Steps for adding or changing behavior (a new option, command, endpoint, field or format). Use for "add / support / implement X" tasks.
---

# Feature

Load these steps into the todo tool first. A step you skip stays in the list as `skip: <reason>`.

1. Learn the area. Find where similar features live and copy their pattern (grep for a sibling feature, read it).
2. Name the data shape first: the types, fields and formats the feature adds or changes, and where each lives.
3. Remove what the change makes obsolete before adding to it.
4. Build in small units. After each unit, run a check (build, test or the command itself) before the next one.
5. Add tests for the behavior a user observes, with literal expected values.
6. Update the docs, help text, changelog or README the feature touches.
7. Prove it end to end. Run the real command or flow and show its output, not only "tests pass".
8. Report: what you built, choices you made and why, and anything left open.
