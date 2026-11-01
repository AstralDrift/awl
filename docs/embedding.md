# Running awl from another program

This page is for programs that run awl as a child process: a sandbox runner, CI, a
benchmark harness. Hearth is one. It runs `awl -p` inside
bubblewrap with a cleared environment, then reads awl's session file to fill in its receipts.
Everything here is checked by `tests/embed.sh` (part of `zig build e2e`). A change to any of it is
a breaking change. It ships behind a new setting, with the old form kept working, and the
release notes say so.

## Pin a release

Releases attach `awl-linux-x86_64`, `awl-linux-aarch64` and `SHA256SUMS` (`sha256sum` format).
These names and that format are stable. See [Building a release](../README.md#building-a-release)
to rebuild one and compare. `awl --version` prints one line on stdout and exits 0:

    awl 0.1.0 (8d7c9ae)

That is the `build.zig.zon` version and the first 7 digits of the commit, or `(unknown)` for a build
made without git.

## One run: `awl -p TASK`

`awl -p TASK` runs one task without a TUI and exits. It never asks anyone anything, at a terminal
or not, and it does not read stdin. A step that would need a person is refused, and the result
the model gets says why (see [Tool results](#tool-results)).

- **stdout**: the model's text. Each reply that has text goes on its own line, and the final reply
  comes last.
- **stderr**: progress for people (tool lines, notes, errors). Not a stable format.
- **Exit status**:

| Status | Meaning |
|---|---|
| 0 | The model finished: a reply with no tool calls. |
| 1 | The run stopped early: it hit the step limit (`AWL_MAX_STEPS`), or the model could not be reached or kept failing after retries. At the step limit awl first asks for one last report with tools off. |
| 2 | Bad arguments or settings (`AWL_URL`, `AWL_MODE`), or no model at `AWL_URL` and no `AWL_MODEL`. Nothing ran. |
| 130 | SIGINT: the running command was stopped and the run ended. |

awl handles SIGINT only. SIGTERM and SIGKILL end it at once, and the session file then ends wherever
the run had reached. Background jobs the model started are stopped when awl exits, unless it is
killed.

## Environment

awl reads only its environment; it has no config file. An embedder sets:

| Variable | Use |
|---|---|
| `AWL_URL` | OpenAI-compatible base URL, e.g. `http://127.0.0.1:8080`. awl sends `/v1/models` and `/v1/chat/completions` under it. |
| `AWL_KEY` | Sent as `Authorization: Bearer <key>`. **When it is set, even to the empty string, awl uses it as is and never reads a key file.** Unset, awl reads `$HOME/.local/state/omarchy/local-ai/gateway.key`. An embedder should always set it. |
| `AWL_MODEL` | Model name. Unset, awl uses the first model `/v1/models` lists. |
| `AWL_MODE` | `auto` (no approvals), `ask`, or `plan` (files read-only). Under `-p` nobody can approve, so `ask` behaves like `auto` except for the refusals below. |
| `AWL_MAX_STEPS` | Model replies per run (default 200). |
| `AWL_NETWORK` | `off`: a command that asks for the network (`network: true`) is refused at once, with `not run: AWL_NETWORK=off: …` as its result, and `AWL_SANDBOX_NET=on` is ignored. The model is told in its system prompt. Any other value, or unset: the default (no network for commands; under `-p` a `network: true` command is refused because nobody can approve it). |
| `HOME` | Where awl looks for the user's files (below). |
| `XDG_STATE_HOME` | Session files go to `$XDG_STATE_HOME/awl/sessions/`, else `$HOME/.local/state/awl/sessions/`. |
| `XDG_CONFIG_HOME` | User config, else `$HOME/.config`. |

The model's commands get awl's environment minus every variable that starts with `AWL_`, so
`AWL_KEY` never reaches them. Any other variable you set does reach them.

`awl -h` lists the other settings. Leave `AWL_SANDBOX` unset: awl then runs every command in its own
bubblewrap sandbox with no network, and refuses commands when `/usr/bin/bwrap` is missing or cannot
start.

`AWL_NETWORK=off` is a policy on what commands ask for. Commands are actually kept off the network by
awl's sandbox (bubblewrap with its own network namespace). With `AWL_SANDBOX=off` there is no sandbox,
and a command that does not say it needs the network can still reach it.

### Sockets under `/tmp`

Unix sockets let a command act outside the sandbox, so when the session sandbox starts (at the
first command) awl hides every socket at `/tmp/NAME` and `/tmp/DIR/NAME`, and all of `/tmp/.X11-unix`
and `/tmp/.ICE-unix`. It hides them by mounting `/dev/null` over each one. Sockets deeper than that,
like `/tmp/DIR/SUB/NAME`, and sockets created after the sandbox started, stay reachable. This depth
is tested (`tests/sandbox.sh`) and will not change without a release note.

To give commands one socket of yours on purpose, name it: `AWL_SANDBOX_SOCKETS=/tmp/run-1/web/fetch.sock`
(`:`-separated full paths, matched exactly). Every other socket stays hidden. Prefer this to relying on
the depth.

### What awl reads under `HOME`

Your scratch `HOME` is part of the contract. awl reads, if present:

- `$XDG_CONFIG_HOME/awl/AGENTS.md`, else `$HOME/.config/awl/AGENTS.md`: the user's own rules, sent
  before the project's `AGENTS.md` files. This is the place for an embedder's instructions (Hearth
  writes one to say the session is offline).
- `$XDG_CONFIG_HOME/awl/prompts/`, else `$HOME/.config/awl/prompts/`: slash-command prompts (TUI only).
- `$HOME/.agents/skills/`: user skills, listed in the system prompt.
- `$HOME/.local/state/omarchy/local-ai/gateway.key`: only when `AWL_KEY` is unset.
- `$HOME/.local/state/omarchy/current/theme/colors.toml`: TUI colors only.

It writes only session files, and in the TUI a status file next to them. `-p` writes no status file.

## The session file

One file per run, `$XDG_STATE_HOME/awl/sessions/<YYYYMMDD-HHMMSS>-<pid>.jsonl` (`_1`, `_2` appended
if two start in the same second). The newest name sorts last. One JSON object per line:

1. A meta line: `{"awl":"0.1.0","model":"…","cwd":"…"}`. Skip any line that has an `"awl"` key.
2. Then OpenAI chat messages, in order, as sent to the model:
   - `{"role":"user","content":"…"}`
   - `{"role":"assistant","content":"…","tool_calls":[{"id":"…","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls\"}"}}]}`.
     `content` and `tool_calls` may each be missing. `arguments` is a JSON string, as the model wrote
     it, and may not be valid JSON. The message may also carry `reasoning_content`.
   - `{"role":"tool","tool_call_id":"…","content":"…"}`: one per call, after its assistant message, in
     call order. Ids are the model server's and can repeat across turns, so match each call to the
     first unused tool message after it.

Lines are only appended. When a long run compacts its context, awl appends the summary it now
sends in place of older messages; the older lines stay. Old tool output is cut in what is sent to
the model (`[old tool output elided …]`), never in the file.

## Tool results

The tools are `read`, `write`, `edit`, `bash`, `grep`, `find` and `todo`. A `bash` call's arguments are
`command`, plus optional `timeout` (seconds, default 120), `background` and `network` (booleans).

A `bash` result is the command's output (stdout and stderr together, the tail kept if it is long),
then:

| Ending | Meaning |
|---|---|
| `\n[exit N]` | Exited with code N ≠ 0 (128 + signal number if killed by one). May be followed by hint lines `[PATH does not exist. …]`. |
| `(no output)` | Exited 0 and printed nothing. Exit 0 with output has no marker. |
| `\n[timed out after N s; process group killed]` | Stopped at its timeout. No exit status. |
| `\n[interrupted by user]` | Stopped by SIGINT. No exit status. |
| `\n[ran with network, approved by the user for this command only]` | Ran with the host network (TUI only). |

A background command's result is `started background job N (pid P); output goes to /tmp/awl-…log. …`.
When a background job ends, the next tool result starts with one line per finished job:
`[background job N (CMD) exited with code C; output in LOG]`.

Notes awl adds at the end of a result, each on its own line, for the model's sake:
`[awl: you have made this exact call N times …]`, `[awl stopped your reply here: at most 16 tool calls
run per reply …]`, and `[awl: N steps are left in this run. …]`.

A call that did not run has one of these results instead. Each opening is stable:

| Result starts with | Cause |
|---|---|
| `not run: ` | Refused before it started. Under `-p`: `not run: the network is off in the sandbox and only the user can approve…` or, with `AWL_NETWORK=off`, `not run: AWL_NETWORK=off: …` for `network: true`; `not run: the sandbox did not start: …` or `not run: awl runs the model's commands in a bubblewrap sandbox and /usr/bin/bwrap is missing…`. |
| `[not run: ` | The reply was cut off by the token limit inside this call. |
| `[skipped: ` | An earlier call in the same reply was interrupted. |
| `not written: ` | `write`/`edit` outside the sandbox's writable paths, or to a guarded file (`.git/config`, `.git/hooks`, `AGENTS.md`, `.agents`) with nobody to approve. |
| `invalid arguments for ` | Arguments were not JSON, or a field was missing or of the wrong type. |
| `Plan mode: ` | `AWL_MODE=plan` and the call would change a file. |
| `too many background jobs` | 16 already run. |
| `The user declined` | A person said no (TUI and background agents only, never `-p`). |
| `unknown tool: ` | The model named a tool awl does not have. |
| `spawn pipe: `, `spawn fork: `, `background fork: `, `background /tmp/awl-…` | The system refused a pipe, fork or log file. |

## Running awl inside another sandbox

awl's command sandbox cannot start inside some outer sandboxes (nested user namespaces, a covered
`/proc`). Commands then fail closed with `not run: the sandbox did not start: …`; awl never runs them
unsandboxed on its own. The options, and their risks, are in [nested-sandbox.md](nested-sandbox.md).
