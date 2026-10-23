# AGENTS.md — awl

- Spec is PLAN.md. v1 is done; work now follows the v1.x section: arena evidence decides what ships.
- Zig 0.16.0 via `mise`. Target x86_64-linux-none (static, no libc). Std lib only.
- Footprint goals (soft): binary < 256 KB, idle RSS < 1 MB, peak < 4 MB over 50 turns, start < 1 ms. `zig build check` asserts ceilings of 256 KB / 1.5 MB / 8 MB / 3 ms; raise one only for a feature people use or that wins arena tasks, and say so in the commit.
- Keep it small (~3,000 lines of Zig). Prefer deleting code over adding abstraction.
- Every experiment gets one line in arena/LOG.md: hypothesis, change, result, decision.
- Each phase: write its check first, then make it pass. A commit message carries measured size/RSS/startup. Commit or push only when the user asks.
- Never commit gateway keys, sessions, or raw arena transcripts.
