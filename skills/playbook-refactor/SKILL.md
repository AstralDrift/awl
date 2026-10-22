---
name: playbook-refactor
description: Steps for behavior-preserving changes: rename, move, extract, inline, change a signature across callers. Use for "rename / refactor / clean up X" tasks.
---

# Refactor

Load these steps into the todo tool first. A step you skip stays in the list as `skip: <reason>`.

1. Capture the current behavior: run the tests, or record the program's output on a few inputs, before touching code.
2. Find every use. Grep for the name and its variants (imports, aliases, strings, docs). Note look-alikes that must not change, such as unrelated local functions with the same name.
3. Change the definition, then migrate every caller in the same pass. Leave no alias for the old name unless asked. Use one edit call with an edits list per file.
4. Grep again: the old name should appear only where it is meant to.
5. Prove behavior is unchanged: rerun step 1 and compare. Show the output.
6. Report: what moved or changed, how many call sites, and the proof.
