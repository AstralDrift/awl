# AGENTS.md — awl

- Spec is PLAN.md. v1 is done; work now follows the v1.x section: arena evidence decides what ships.
- Zig 0.16.0 via `mise`. Target x86_64-linux-none (static, no libc). Std lib only.
- Goal: the best, most performant open-source agent harness: most tasks solved, fastest, best to use, on any model. Results, speed (wall time, tokens per request, startup) and the user's experience come first. Lines of code do not matter. Prefer deleting code over adding abstraction.
- Build like the old-school devs who counted every byte: frugal by habit. Reach for the leaner design when it is just as good (lazy buffers, no allocation in hot paths, no new dependency, nothing resident that is not used), measure what a change costs, and say so in the commit. But footprint never blocks innovation: a feature that makes awl better ships even when it costs memory or size, done as lean as it reasonably can be. There is no binary size or idle memory limit (`zig build check` reports both). It asserts ceilings of 8 MB peak RSS / 3 ms startup to catch regressions; raise one when a better feature needs it, and say so in the commit.
- Every experiment gets one line in arena/LOG.md: hypothesis, change, result, decision.
- Each phase: write its check first, then make it pass. A commit message carries measured size/RSS/startup. Commit or push only when the user asks.
- Never commit gateway keys, sessions, or raw arena transcripts.
