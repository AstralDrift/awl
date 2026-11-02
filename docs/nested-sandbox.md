# awl inside another sandbox: options (not decided)

Status: a write-up for the owner to decide on. awl's behavior is unchanged. awl never falls back to
running commands unsandboxed on its own.

## The problem

awl runs every model command in a bubblewrap sandbox of its own (`--unshare-user --unshare-pid
--unshare-net --proc /proc`, `/` read-only, `/tmp` and the project writable). Hearth runs awl
itself inside Hearth's bubblewrap. There, awl's sandbox cannot start, for two reasons that Hearth's
`docs/awl.md` ("Nested sandbox") shows with evidence:

1. Ubuntu's AppArmor rule for unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`)
   denies awl's bwrap the capabilities it needs to set up loopback. Hearth's `--disable-userns` now
   refuses the nested namespace outright.
2. The kernel allows a new `/proc` mount in a nested user namespace only where a fully visible `/proc`
   is already mounted. Hearth's `/proc` has locked covers on `/proc/sys` and others.

So under Hearth every command fails closed with `not run: the sandbox did not start: …`. awl can still
read and edit files.

## What awl's own sandbox adds inside Hearth's

Hearth's sandbox already limits writes to the scratch copy, has only loopback, and drops capabilities.
awl's sandbox adds, for commands only:

- **A separate network namespace.** Commands cannot reach Hearth's loopback relay port, so they cannot
  send their own requests to the model endpoint.
- **A separate PID namespace and a fresh `/proc`.** Commands cannot see awl's process. Without it, a
  command running as the same user can read `/proc/<awl>/environ`, which holds `AWL_KEY` (awl strips
  `AWL_*` only from the environment it passes down), and can `ptrace` awl if Yama allows it.
- **Socket hiding under `/tmp`.** Hearth's relay socket, `/tmp/hearth-awl-<id>/relay.sock`, is hidden.
  The web helper socket one level deeper is not (see docs/embedding.md).
- **Read-only guarded files** (`.git/config`, `.git/hooks`, `AGENTS.md`, `.agents`) and hidden secrets
  under `$HOME`. Inside Hearth, `$HOME` is a scratch directory, so this matters less there.
- **Environment.** `HEARTH_AWL_RELAY_SOCKET` and `HEARTH_AWL_RELAY_PATH` reach commands either way,
  because awl strips only `AWL_*`. They name the relay socket, so commands would not have to find it.

## Options

### A. Keep failing closed (today)

- Safe: nothing a command could do is possible, because no command runs.
- Cost: Hearth's tasks cannot run tests, builds or any shell command. Many tasks fail or give
  unverified edits. `HEARTH_AWL_CHECK` still tests the diff afterwards, outside awl.

### B. A mode where awl trusts the outer sandbox (`AWL_SANDBOX=outer`)

awl runs commands directly (no bwrap), keeps its write/edit path rules, and says in the system prompt
and results that the outer sandbox is the only one. Opt-in only, never a fallback.

Risks, all inside Hearth's sandbox:

- Commands reach the relay (by port on loopback, or via `relay.sock`, whose path is in their
  environment). They can send any bytes to the declared model endpoint: requests with a model key
  they read from awl's `/proc/<pid>/environ`, spending the user's tokens or reaching other paths on
  that host and port. The endpoint is the only host they can reach.
- Commands can read awl's memory and environment (`/proc`, `ptrace`) and signal or kill awl.
- Commands can connect to every socket Hearth puts in the scratch directory.
- A model that read a prompt injection gets everything Hearth's sandbox allows, with no inner layer.

If chosen, it would need at least: awl drops `HEARTH_*`-style variables it is told to (a scrub list),
and Hearth binds no socket the commands should not use. It cannot hide awl's process from its own
commands without a PID namespace, which is the thing that does not work here.

### C. awl hands each command to an outer executor (`AWL_EXEC=<program or socket>`)

awl sends the command (argv, cwd, timeout, the `network` flag) to a program the embedder names, and
uses whatever that returns as the result. Hearth would run each command in a fresh sibling bwrap,
the way it already runs `HEARTH_AWL_CHECK`: a fresh `/proc`, no relay, no key, no awl process to see.

- Safe: the isolation is at least what awl's own sandbox gives, set up by the outer program, which can
  create namespaces.
- Cost: real work on both sides. awl's session sandbox is one long-lived namespace. Background jobs, a
  server started by one command and reached by the next, and a shared `/tmp` all depend on it, so the
  executor would need one sandbox per awl session, not per command, or those features change.
  Hearth would own the executor and its tests. Each call adds a little latency (a process start).
- This is the direction Hearth's own write-up suggests ("an awl mode that hands commands back").

### D. A namespace-free inner layer: Landlock and seccomp

awl applies Landlock (filesystem rules, and TCP connect/bind rules on kernels from 6.7) and a seccomp
filter in the forked command before `execve`, with no user namespace needed.

- Good: works inside Hearth's sandbox, keeps commands off the relay port, can deny `ptrace`.
- Gaps: it does not hide processes or `/proc/<awl>/environ` the way a PID namespace does. Coverage of
  connecting to pathname Unix sockets and of signals depends on the kernel's Landlock ABI version.
  That needs checking on each target kernel (Ubuntu 22.04's 5.15 has neither the TCP nor the scoping
  rules). It would be a second sandbox to maintain next to bubblewrap.

## Separate finding: the session file is writable from inside

Under Hearth, `XDG_STATE_HOME` is `/tmp/hearth-awl-<id>/state`. awl's `write` and `edit` tools allow
any path under `/tmp`, and awl's command sandbox mounts `/tmp` writable. So the model can overwrite its
own session transcript (with `write` alone, today, without running a command), and Hearth fills its
receipts from that file. Hearth already treats the scratch directory as hostile and hashes the
transcript, but the hash is of whatever the file holds at the end. A fix in awl, independent of the
options above: make awl's session directory non-writable to `write`/`edit` and mount it read-only in
the command sandbox. Found by reading `src/sandbox.zig` and `src/tools.zig`; no test yet.

## Recommendation

C is the only option that keeps commands as isolated as they are outside Hearth. B is quick, but it
puts the relay and awl's key in reach of every command. D is worth it only if C proves too heavy.
Until the owner decides, A stays.
