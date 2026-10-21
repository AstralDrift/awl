# AGENTS.md — awl

- Spec is PLAN.md. Scope is v1 exactly; anything else goes under "Later".
- Zig 0.16.0 via `mise`. Target x86_64-linux-none (static, no libc). Std lib only.
- Budgets: binary ≤ 200 KB, idle RSS ≤ 1.5 MB, peak ≤ 8 MB (excl. tool output), start ≤ 3 ms. `zig build check` asserts them.
- ~3,000 lines of Zig for v1. Prefer deleting code over adding abstraction.
- Each phase: write its check first, make it pass, commit with measured size/RSS/startup, push to origin.
- Never commit gateway keys, sessions, or raw arena transcripts.
