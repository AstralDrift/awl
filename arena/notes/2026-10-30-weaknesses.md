# Five weaknesses, ranked (2026-10-30)

Written before touching code, as the brief asked. Evidence is the LOG (line numbers refer to
arena/LOG.md rows by date), the source, and runs made today.

Where this was done: a macOS laptop with no GPU, no reachable Omarchy desktop and no OpenRouter
key. awl cross-compiles here (`zig build -Dtarget=x86_64-linux`, 356,480 B) and the offline suite
runs in an x86_64 Debian container (`arena/notes/linux-rig.md`). So every item below gets its
check and its offline numbers here; the live A/Bs (Qwen3.8-27B on the desktop, one cloud model)
are listed as pending with the exact commands.

## 1. Reasoning sent back on every turn inflates every prompt on Qwen-template models

- `AWL_KEEP_REASONING` defaults to on since 2026-10-26 (LOG: "Reasoning sent back with its turn").
  Its rationale was a prefix-cache claim ("without it the re-rendered history differs from the
  generated tokens and the prefix cache misses from the first assistant turn on") and the LOG says
  "Live effect NOT yet measured".
- Qwen3's chat template (fetched from Qwen/Qwen3-8B) renders `reasoning_content` for **every**
  assistant turn after the last real user message (`last_query_index`; tool results do not count as
  user messages). In an agent run that is every turn. At ~1K reasoning tokens per step (medium
  effort) a 40-step run carries ~40K tokens of past reasoning in each request.
- The prefix-cache claim does not hold either way: the cache always covers the previous request's
  prompt; what differs is only the newest turn's rendering (content + tool call, a few hundred
  tokens). The thing that is re-prefilled on a cache miss is the whole prompt, and that is what
  keep-on doubles.
- The only Terminal-Bench run after the change (2026-10-28 night) had awl at 10/20 (was 12/20 on
  10-23) with a 52% cache hit vs pi's 60%; the LOG calls the pass-rate move noise. Wall time on
  the local engine is ~99% model time and the misses are timeouts (LOG 10-27, 10-28).
- Hypothesis: off halves prompt tokens late in long runs and cuts wall time on the local engine
  with no pass-rate loss. Check first: a template render over a synthetic 30-step history (both
  settings) counting the prompt. Live A/B pending.

## 2. The arena's token counts are wrong for replies awl stops mid-stream

- LOG 2026-10-27 (--dev): "Proxy logs 0 completion tokens for replies awl stops mid-stream
  (undercount)". awl closes the connection on a reply past 16 tool calls, past AWL_THINK_MAX, or
  on Ctrl-C; the proxy then never sees the usage event and records 0 for that reply.
- The brief says to fix the benchmark first when it measures the wrong thing. Token comparisons
  between harnesses are a headline number in the README.
- Fix: the proxy counts what streamed when the client went away (content and reasoning chars, as
  an estimate marked as such) instead of 0. Check: test_proxy.py case.

## 3. The system prompt tells the model it is on Omarchy Linux wherever it runs

- `src/agent.zig` base_prompt: "a coding agent in a terminal on Omarchy Linux", unconditionally.
  Terminal-Bench task containers are Debian/Ubuntu; the user's coworkers run other Linux laptops,
  WSL and dev containers. A model told "Arch" reaches for pacman and Arch paths.
- No LOG evidence of a task lost to it, so expected impact is small but the fix is one line:
  name the OS from /etc/os-release (PRETTY_NAME) and say nothing when there is none.

## 4. A foreground command is killed at its timeout and its work is lost

- `bash` default timeout 120 s; at the timeout the process group is killed (tools.zig spawn). A
  build or test run that needs 3 minutes costs the run twice: the kill and the rerun with a
  bigger timeout. pi has no timeout at all (harness-study.md); Grok moves the command to the
  background and returns a task id.
- The 10-28 miss analysis found "no tool waits" in the two lost tasks, so this is robustness, not
  the Terminal-Bench fix. It makes awl strictly better than both rivals on long commands: at the
  timeout the command keeps running as a background job and the model gets the output so far,
  the job id and the log path.
- Check: e2e, a `sleep 3; echo done` with timeout 1 returns at ~1 s, and the log later holds
  "done".

## 5. No TLS and no DNS: cloud use needs a Python sidecar

- http.zig: "Plain HTTP only (localhost)", IPv4 literal or localhost (parseUrl). The README's
  "or OpenRouter in the cloud" goes through arena/proxy.py (awl-or.sh), which also opens a new
  TLS connection per request upstream.
- "On any model" and "best to use" for Linux laptops, WSL and dev containers means
  `AWL_URL=https://openrouter.ai/api AWL_KEY=…` must just work.
- Risk: Zig 0.16 std.crypto.tls and the new std.Io API, plus certificate loading without libc;
  size grows. Spike first (30 minutes); build only if the std API is tractable.

## Not ranked, noted

- Dev containers and WSL without bubblewrap: every command is refused until the user sets
  `AWL_SANDBOX=off`. The message says so, but a one-line hint at startup when awl is already
  inside a container (/.dockerenv, /run/.containerenv) would save the first confused minute.
- Elision keeps every checklist message, not only the newest (agent.zig elide()).
- Stale-read / duplicate-output elision and a completion critic (research-2026-10.md) need live
  runs to say anything; left for later.
- macOS: the user is open to it; awl is Linux syscalls only. A port is a project of its own.

## What the arena measures

- Local Terminal-Bench is ~99% model time and the misses are timeouts at 2-at-a-time with a
  thrashed cache (LOG 10-28): it ranks engine speed and prompt size more than harness logic.
  Tokens per solved task and steps per solved task are the harness-sensitive numbers; wall time
  only at one trial at a time. The LOG already says this; nothing to fix beyond item 2.
- T3 is saturated (20/20 for every harness since 10-21); the signal there is tokens and turns.
