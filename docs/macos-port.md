# Native macOS port: design and go/no-go

**Recommendation: go.** awl can run natively on macOS with a Seatbelt sandbox that meets the
claims of the README's Safety section: all 71 checks pass on this Mac (0 fail), the toolchain
works inside it, and three claims come out stronger than on Linux. It is not the *same*
guarantee in one respect: a localhost private to the session cannot be met on macOS, and it was
decided on 2026-11-14 that commands get a reserved block of localhost ports instead (section
3.4). Six further claims hold in a different shape (no `ps`, no nested sandboxes, sockets named
rather than scanned; section 3.3). The first version of this spike had one failing claim, a
command reading other processes' environments; it is closed (two profile rules, section 3.3).
The OS layer is small and mechanical (459 `std.os.linux` uses, 276 of them plain POSIX), and
linking libSystem costs about 1 ms of startup and 1.7 MB of resident memory, inside both ceilings.
Estimated size: about 2,650 changed lines in four phases (section 5). No port code is in this
branch; the port starts after thread A's sandbox changes land.

Everything measured here was measured on one machine: Apple silicon, macOS 27.2.1 (26B131),
Zig 0.16.0, 2026-11-14. Nothing was run on an Intel Mac or on a GitHub runner.

Reproduce (from a plain terminal: Seatbelt sandboxes do not nest, so neither script works inside
Claude Code's command sandbox or any other one):

    bash spike/macos/probes.sh     # the sandbox probes, one line per claim
    sh spike/macos/measure.sh      # size, startup, RSS, and what the sandbox costs per command

`spike/macos/` is throwaway: `awl.sb` (the profile), `probes.sh`, `control.zig` and `shape.zig`
(the libSystem spike), `sbinit.zig` (sandbox cost, and the holder's job check), `scrub.zig`
(hiding awl's own key), `procargs.zig` (a probe tool), `measure.sh`.

## 1. OS-layer inventory

`grep -noE 'linux\.[A-Za-z_0-9]+(\.[A-Za-z_0-9]+)?' src/*.zig` finds **459 uses in 17 of the 21
modules**. Per module: tools 107, sandbox 84, agents 62, tui 51, sys 43, http 26, session 25,
undo 16, dns 12, buf 7, summary 7, dash 6, ui 4, prompts 3, skills 3, main 2, tls 1.
**Already portable (0 uses): `agent.zig`, `jint.zig`, `llm.zig`, `screen.zig`.**

Three things the task brief assumed that the code does not do:

- **There is no epoll.** awl waits with `poll(2)` (6 call sites). `poll` exists on Darwin, so the
  event loop needs no kqueue rewrite. (`PLAN.md` line 8 still says "epoll".)
- **There is no timerfd.** Timeouts are `poll` timeouts and `clock_gettime`.
- **`sys.zig` is not a seam today.** Only 43 of the 459 uses are in it; the other 416 call
  `std.os.linux` directly from 16 modules.

And one thing the compiler will not tell you: `zig build -Dtarget=aarch64-macos` **already
succeeds** on today's tree with no error and produces a 734,112-byte Mach-O. The raw-syscall
wrappers are inline assembly that compiles for any aarch64 target, so that binary would issue
Linux syscall numbers to the Darwin kernel. It must never be run, and the port needs a lint rule
(`std.os.linux` allowed only in `src/sys/linux.zig` and `src/sandbox/linux.zig`) because the
type checker gives no help.

### Groups, by what replaces them on Darwin

Line numbers are for commit 75be427; thread A is about to move `sandbox.zig` and `tools.zig`.

| Group | Uses | Where | On Darwin |
|---|---|---|---|
| **Return convention** (`linux.errno(rc)`, `linux.E`) | 60 | 13 modules; densest: sandbox 15, tools 14, agents 8, sys 7 | The biggest diff driver. Raw syscalls return `-errno` in a `usize`; libSystem returns -1 and sets `errno`. Every call site moves behind `sys.*` functions that return `sys.Error!T`. |
| **Process control** (`fork` 14, `execve` 10, `wait4` 13, `kill` 9, `dup2` 18, `getpid` 16, `pid_t` 10, `exit`/`exit_group` 22, `setsid` 3, `setpgid` 1, `getuid` 1, `chdir` 2, `getcwd` 3, `pipe2` 4) | 126 | tools, sandbox, agents, tui | Same calls in libSystem. Two exceptions: `pipe2` does not exist (sandbox 209; tools 1112, 1231, 1235) -> `pipe` + `fcntl(F_SETFD, FD_CLOEXEC)`; `exit_group` -> `_exit`. `wait4` status decoding (sandbox 329) is the same encoding. |
| **Files** (`AT.FDCWD` 30, `unlinkat` 18, `open`/`openat` 8, `renameat` 4, `mkdirat` 4, `read`/`write`/`writev`/`pread`/`pwrite` 7, `flock` 2, `ftruncate` 2, `faccessat`, `symlink`, `unlink`, `mkdir`, `rmdir`, `close`, `O`, `mode_t`, ...) | 90 | all 17 | Same calls. Flag values differ (`O_CLOEXEC`, `O_DIRECTORY`, `AT_FDCWD` is -2), so flags go through `sys`. `O_PATH` (`.PATH = true`, sandbox 416) does not exist; see "Real path of a descriptor". |
| **Directory listing** (`getdents64` 11, `dirent64` 22, `DT.*` 4) | 37 | agents 456-462, 551-557; prompts 123-129; sandbox 165-178; session 165-170, 434-440, 585-590; skills 78-84; tools 566-571, 604-611; tui 1932-1945 | `__getdirentries64` (the spike read 8 entries with it). The record layout differs (`d_seekoff`, `d_namlen`), so the eleven hand-rolled loops become one `sys.Dir` iterator; that also deletes code on Linux. |
| **Sockets** (`socket`, `connect`, `sockaddr.in`, `fcntl` `F.GETFL`/`SETFL`, `getsockopt` `SO.ERROR`, `setsockopt` `TCP.NODELAY`, `sendto`, `recvfrom`, `AF`/`SOCK`/`SOL`/`IPPROTO`) | 27 | dns 52-60; http 104-121 | Same calls, different constants (`SOL_SOCKET` 0xffff, `O_NONBLOCK` 4), `sockaddr_in` starts with a length byte, and `SOCK_CLOEXEC` (dns 52, http 104) does not exist -> `fcntl`. |
| **poll loop** (`poll` 6, `pollfd` 6, `POLL.IN`/`OUT` 11) | 23 | agents 186-187; dns 56-57; http 71-83, 113; tools 1303-1308; tui 558-562, 616-617 | Unchanged: `poll(2)`. A kqueue descriptor is itself pollable (spike: one `poll` over a pipe and a kqueue), so the two replacements below slot into the existing poll sets. |
| **statx** (`statx` 7, `Statx` 7, `AT.EMPTY_PATH` 4, `S.ISDIR`/`ISREG` 2) | 20 | agents 502-503; dash 821-823; session 534-535; tools 656-659, 756-757; ui 40-41; undo 77-78 | `fstat` / `fstatat`. awl only reads size, mtime and mode, so one `sys.stat(fd_or_path) -> {size, mtime, kind, mode}`. |
| **Sandbox namespaces** (`setns` 2, `CLONE.NEW*` 7, `prctl` 4, `PR.*` 4, `pidfd_open` 1, `SIG.KILL` as pdeathsig 1) | 19 | sandbox 74, 78, 252, 271, 300-301, 316-317, 321 | **Nothing.** No namespaces, no `setns`, no `prctl`. Replaced by the Seatbelt design in section 3. `PR_SET_PDEATHSIG` has no equivalent: the holder watches its parent with kqueue `EVFILT_PROC` instead. |
| **Terminal** (`ioctl` 7, `T.IOCGWINSZ` 3, `T.CGETS`/`CSETS`/`CSETSW` 4, `termios`, `V.MIN`, `V.TIME`) | 17 | sys 80, 85, 91; tui 19, 34-36, 43, 194, 1812 | `tcgetattr`/`tcsetattr` (or `TIOCGETA`/`TIOCSETA`); `termios` has a different layout and 8-byte flag words; `TIOCGWINSZ` has another number. |
| **Signals** (`sigprocmask` 2, `sigemptyset`/`sigaddset` 6, `signalfd` 1, `signalfd_siginfo` 1, `SFD.*` 2, `SIG.BLOCK`/`SETMASK` 2) | 14 | sys 170-185 | `sigprocmask` is the same. **`signalfd` does not exist** -> kqueue `EVFILT_SIGNAL` (spike: registered, pollable). `sys.sigfd` keeps its meaning: a descriptor that turns readable on SIGINT. |
| **Memory** (`mmap` 3, `munmap` 2, `madvise` 3, `MADV.*` 3) | 11 | buf 20, 24, 60, 80; tools 648, 666; tui 531, 533 | `mmap` is the same; `MAP_NORESERVE` and `MADV_NOHUGEPAGE` do not exist (drop: anonymous memory is lazy anyway). `MADV_DONTNEED` (buf 80) does not lower RSS on Darwin: use `MADV_FREE_REUSABLE`, and re-measure peak RSS. |
| **Time** (`clock_gettime` 2, `timespec` 4, `nanosleep` 2) | 8 | sys 67-74; tools 1211-1212, 1680-1681 | Same calls. |
| **Real path of a descriptor** (`readlink` 3, two of them on `/proc/self/fd/N`) | 3 | sandbox 422, 446 (and 435, a plain dangling-link check) | `fcntl(fd, F_GETPATH, buf)`. Spike and probes: it returns the canonical path (`/tmp` -> `/private/tmp`) in the on-disk case (`~/.SSH/ID_PROBE` -> `~/.ssh/id_probe`). `resolve()` and `fdPath()` keep their contracts, with one change measured here: without `O_PATH` the prefix is opened `O_RDONLY\|O_NONBLOCK` (plain `O_RDONLY` and `O_EVTONLY` block on a FIFO; `O_SYMLINK` returns the link, not its target), and that needs read permission, so a mode-000 file gives EACCES where Linux gives a path. `resolve()` must then fall back to the parent's real path plus the leaf name, after checking the leaf is not a symlink. |
| **Random** (`getrandom`) | 3 | dns 50; tls 84; tools 751 | `arc4random_buf` (cannot fail) or `getentropy`. |
| **Child-exit notice** (`pidfd_open`) | 1 | tools 1290 | kqueue `EVFILT_PROC` + `NOTE_EXIT`, polled next to the pipes exactly as the pidfd is. Spike: the exit was seen in the same `poll` as the output. If the child is already gone `kevent` returns ESRCH: treat as exited. |
| | **459** | | |

### Linux paths and tools that are not syscalls

| What | Where | On Darwin |
|---|---|---|
| `/proc/self/exe` (re-exec for background agents) | agents 174 | `_NSGetExecutablePath` (spike: works) |
| `/proc/self/status` `VmHWM`/`VmRSS` | sys 147 | `getrusage` `ru_maxrss` (in **bytes** on macOS, KB on Linux) for the peak; `proc_pid_rusage` or `task_info` for current |
| `/proc/self/fd/N` | sandbox 419, 444 | `F_GETPATH` (above) |
| `/proc/sys/user/max_user_namespaces` | sandbox 272 | not applicable |
| `/usr/bin/bwrap` | sandbox 16 | Seatbelt is part of the OS: nothing to install, nothing to find |
| `/usr/bin/rg`, `/usr/bin/fd` | tools 139-140 | System Integrity Protection forbids installing into `/usr/bin`. Homebrew puts them in `/opt/homebrew/bin` (Apple silicon) or `/usr/local/bin` (Intel): look them up in a short fixed list, then `PATH`. |
| `/usr/bin/notify-send` | agents 248, tui 513 | none built in without Apple Events; use the terminal's own notification escape (OSC 9 / OSC 777) or drop on macOS |
| `/etc/os-release`, `/.dockerenv` | agent 83, 99 | `sysctl kern.osproductversion` -> "macOS 27.2" |
| TLS roots | tls 125-128 | `/etc/ssl/cert.pem` is already the fourth entry and exists on macOS: **no change**. It does not include roots a user or company added to the Keychain (`AWL_CA_FILE` covers that). |
| `/etc/hosts`, `/etc/resolv.conf` | dns 11, 14 | Both exist. `resolv.conf` is generated and lists the primary resolvers only: VPN split DNS and `.local` names will not resolve. Acceptable for an API host; say so in the README. |
| `/tmp/awl-*` logs and scratch files | tools 1098, 1105, 1275; tui 735, 1803; undo 161 | Work as they are (`/tmp` is a link). But the in-process rule `under(p, "/tmp")` (sandbox 467) compares against a resolved path, which is `/private/tmp/...`: it must test `/private/tmp` and the per-user temp dir. |
| `/bin/bash` | tools 116, 309, 1127 | Exists, but it is **bash 3.2** (2007). Model-written bash 4 syntax (`mapfile`, `declare -A`, `${x,,}`) fails. Tell the model in the system prompt line that already names the OS. |

## 2. libSystem

macOS has no stable syscall ABI (Apple changes syscall numbers and argument conventions between
releases, and Go's attempt to bypass libSystem was reverted for that reason), so the Mac build
links `libSystem.B.dylib` and nothing else. Zig ships the libSystem stubs: the spike
builds with `-target aarch64-macos -lc` (this Mac has Xcode, so "no SDK needed", which is what
lets Linux CI build the Mac release, is Zig's documented behaviour and not checked here), and Zig's linker ad-hoc
signs the binary (required on Apple silicon).

### Measured (`sh spike/macos/measure.sh`, ReleaseSmall, stripped, single-threaded)

`control` is an empty `main`: the floor that dyld and libSystem set. `shape` is awl's shape:
a lazy 4 MB `mmap` region, a non-blocking socket read through `poll`, `fork` + `execve` with a
pipe, kqueue for the child's exit and for SIGINT, `F_GETPATH`, `__getdirentries64`,
`_NSGetExecutablePath`, `getrusage`. (A socketpair stands in for TCP.)

| | Size | Startup (hyperfine, 300 runs) | Peak RSS |
|---|---|---|---|
| `control` (empty, libSystem) | 49,848 B | 1.0 ms ± 0.1 | 1,680 KB |
| `shape --version` (exit at once) | 52,056 B | 1.0 ms ± 0.0 | 1,680 KB |
| `shape` (runs everything, one child) | 52,056 B | 2.5 ms ± 0.3 | 1,760 KB |
| `/usr/bin/true` (Apple's, for scale) | | 0.7 ms ± 0.0 | 944 KB |
| awl today, `aarch64-linux`, static | 681,336 B | (Linux; CI asserts ≤ 3 ms) | (Linux; CI asserts ≤ 8 MB) |
| awl today compiled as Mach-O (not runnable) | 734,112 B | | |

What that means against the two asserted ceilings:

- **Startup: 1.0 ms of the 3 ms ceiling is dyld**, before `main`. awl's own startup work is
  not affected by libSystem (the same code runs), so `awl --version` should land near 1.1 ms.
  The ceiling holds; the margin is smaller than on Linux.
- **Peak RSS: the floor is about 1.7 MB** (16 KB pages, dyld's shared-cache mappings), against
  8 MB. awl's own buffers are the same size on both systems. The ceiling holds. The old "idle
  RSS ≤ 1.5 MB" figure in `PLAN.md` cannot be met on macOS by any program; AGENTS.md already
  says idle RSS is reported, not asserted.
- **Size: about 53 KB more** than the Linux binary for the same source (734 KB against 681 KB),
  from Mach-O layout and 16 KB segment alignment. There is no size limit.

All five Darwin replacements the inventory needs worked in the spike on the first run:
kqueue signal filter, kqueue process filter inside a `poll` set, `F_GETPATH`,
`__getdirentries64`, `_NSGetExecutablePath`.

### How `build.zig` keeps Linux at no-libc

One interface, two implementations, chosen at compile time; no runtime branch, no libc on Linux.

    src/sys.zig            the interface every module imports (what it is today, widened):
                           Error, fd_t, read/write/open/close, stat, Dir, spawn helpers, poll,
                           sigfd, childExitFd, fdPath, random, nowNs, rss, exePath, term
    src/sys/linux.zig      raw syscalls through std.os.linux (today's code, moved)
    src/sys/darwin.zig     extern "c" libSystem calls, kqueue for sigfd and childExitFd
    src/sandbox.zig        the shared part: environment allowlist, path rules, setup, describe
    src/sandbox/linux.zig  bubblewrap holder, setns (today's code, moved)
    src/sandbox/darwin.zig profile text, Seatbelt holder

`sys.zig` picks with `const os = switch (builtin.os.tag) { .linux => @import("sys/linux.zig"),
.macos => @import("sys/darwin.zig"), else => @compileError("awl: Linux and macOS only") };`
and re-exports. `build.zig` changes in three places, about 25 lines:

    const darwin = target.result.os.tag == .macos;
    ... .link_libc = darwin,            // exe, release and test modules; Linux stays false
    // release step: add .macos for both arches -> zig-out/release/awl-macos-{aarch64,x86_64}
    // sandbox step: tests/sandbox_macos.sh when darwin, tests/sandbox.sh otherwise

Estimated diff for the seam alone (phase 0, Linux behaviour unchanged): the 416 uses outside
`sys.zig` are rewritten to `sys.*` calls, about **1,100 lines touched, net about +150**
(`sys/linux.zig` gains what the callers lose; the eleven directory loops and seven statx blocks
collapse into two helpers). The check for that phase is that the Linux release binaries do not
grow by more than 1% and `check`, `e2e` and `sandbox` stay green.

Distribution note for the release phase: an ad-hoc-signed binary downloaded with a browser is
quarantined and Gatekeeper refuses to run it; one fetched with `curl` or installed by Homebrew
is not. Notarization needs a paid Apple Developer ID. That is your decision, not a technical one.

## 3. Sandbox design: Seatbelt

### 3.1 The mechanism and its status

Seatbelt is the kernel sandbox behind the App Sandbox. A process applies a profile (a small
Scheme-like rule language, SBPL) to itself with `sandbox_init`, or `/usr/bin/sandbox-exec`
does it and then execs a command; the profile then holds for that process and every
descendant and cannot be removed. Rules are path, socket, Mach-service and operation filters.
There are no namespaces: nothing is hidden by not existing, everything is refused by rule.

**Status: deprecated, and everywhere.** `man sandbox-exec` on this Mac says "DEPRECATED", and
`sandbox_init` has been marked deprecated in `<sandbox.h>` for over a decade; SBPL was never
documented. Apple still runs its own system on it (this Mac has 553 profiles in
`/System/Library/Sandbox/Profiles`), and it is what Chromium and Firefox (renderer sandboxes),
Bazel, Nix and Homebrew (build sandboxes), Swift Package Manager (manifests and plugins),
OpenAI's Codex CLI and Claude Code (model-run commands) use today. There is no supported
replacement for a command-line program: the App Sandbox needs an app bundle and entitlements
and cannot express "this project directory". The risk is an OS update changing rule
behaviour, not removal next year; the defence is the probe suite running on every macOS
runner image, weekly (CI already has the weekly cron for the same reason on Linux).

### 3.2 Design

- **One sandbox per session, held by a child of awl (the holder), as on Linux.** The holder
  calls `sandbox_init(profile_text, 0, &err)` once and then forks and execs every command awl
  sends it (argv, cwd, environment and the three descriptors over a socketpair, `SCM_RIGHTS`);
  it reports each exit status back. Two measured reasons:
  - *Cost.* Applying the profile per command costs 6.3 ms each time; the holder costs 5.1 ms
    once and nothing after (table below).
  - *Jobs.* A command may signal only processes in its own sandbox, and two `sandbox-exec`
    runs of the same profile are two sandboxes: a later command could not stop an earlier
    command's background job (probe: refused). Commands forked from one holder share one:
    `sbinit.zig` runs two commands from one sandboxed holder, and the second stops the
    background job the first left (measured: ok).
- **No `sandbox-exec` binary.** `sandbox_init` with raw profile text and flags 0 is what
  `sandbox-exec -p` calls; `sbinit.zig` confirms it confines on this macOS. One fewer exec,
  and no dependence on a tool Apple could drop separately from the kernel feature.
- **awl writes the profile text at session start** with the paths in it, like `options()`
  builds bwrap's arguments: ROOT, HOME, the two per-user dirs (`confstr` `_CS_DARWIN_USER_TEMP_DIR`
  and `_CS_DARWIN_USER_CACHE_DIR`), the session view, `AWL_SANDBOX_WRITE` and
  `AWL_SANDBOX_SOCKETS` entries. Paths must be canonical (`/private/tmp`, `/private/var/...`):
  Seatbelt matches the resolved path. About 4 KB of text, built into a static buffer.
- **`network: true` for one command**: not through the holder. A fresh child applies the same
  profile with the network block on and execs (the counterpart of `execOnline`): +4.8 ms on a
  command the user just approved by hand.
- **If `sandbox_init` fails** (awl itself started inside another Seatbelt sandbox: Claude
  Code's, Codex's, an App Sandbox) the model's commands are refused with that reason, exactly
  as a missing bubblewrap is today; `AWL_SANDBOX=off` is the same switch. The `missing`
  message changes from "install bubblewrap" to "already inside a sandbox".
- **The in-process rules for read/write/edit stay in the shared `sandbox.zig`**, with three
  Darwin changes: `/tmp` is `/private/tmp` plus the per-user temp dir; guarded names compare
  without case (below); `hidden()` drops `/proc` and `/run/user` and adds `~/Library` minus
  the developer folders.

What the sandbox costs, 300 commands each (`sbinit.zig`; `/usr/bin/true` as the command):

| | Per command | Once per session |
|---|---|---|
| plain `fork` + `execve` | 1.32 ms | |
| `sandbox_init` in every child | 7.58 ms | |
| through `/usr/bin/sandbox-exec -f awl.sb` (hyperfine) | 7.64 ms (plain: 0.72 ms) | |
| **holder: `sandbox_init` once, then plain forks** | **1.33 ms** | 5.06 ms |

(With the first, shorter profile these were 6.04 ms and 4.48 ms: the cost grows with the rule
count, which is one more reason to pay it once.)

### 3.3 Claim by claim

The claims are the README's Safety section (lines 171-196) and the settings table rows 240-244,
in order. "Probe" names are lines of the output in 3.5. (Thread A's `tests/claims.txt` did not
exist yet when this was written; map it onto this table when it does.)

**Hold as written**

| README claim | On macOS | Probes |
|---|---|---|
| Commands see the filesystem read-only and write only to the project, `/tmp`, build caches and `AWL_SANDBOX_WRITE` | Same. "`/tmp`" becomes `/private/tmp` **and the per-user temp and cache dirs** (`$TMPDIR` is `/var/folders/.../T` on macOS; `mktemp`, compilers and `xcrun` write there). Caches add `~/Library/Caches`. | write to home, LaunchAgents, symlink / hard link / dir symlink out of the project, the toolchain block |
| Hidden: `~/.ssh`, `~/.gnupg`, cloud and gh credentials, keyrings, the Local AI key | Same list, plus what macOS adds: all of `~/Library` (Keychain files, browser profiles and cookies, app tokens, Mail, Messages) except `Caches`, `Developer`, `Python`, `pnpm`, `Java`; `~/.orbstack`, `~/.colima`. The Keychain itself is a Mach service: refused. | sshbash, symlink / hard link to a secret, ~/Library app data, ~/Library/Keychains files, Mach service Keychain |
| Hidden: awl's session files, all but this run's view, read-only | Same (deny the folder, allow the one file to be read, deny writes to all of it). | sessions, otherview, session files: write, this session's view |
| Hidden: the docker socket | Same, and wider: **no Unix socket outside the project connects**, wherever it is. Docker Desktop, OrbStack, colima and podman sockets all live under `$HOME`. | docker, docker socket with the network on |
| Any environment variable not on the allowlist | Same code (`envOk`), no OS involved. | env |
| `.git/config`, `.git/hooks`, `AGENTS.md`, `.agents/` read-only to commands | Same, see "stronger" below for what path rules need that mounts gave for free. | gitconfig, githooks, agentsmd, skills, the three "unchanged" checks |
| No network unless you say yes; `network: true` asks for one command; `AWL_SANDBOX_NET=on`; `AWL_NETWORK=off` | Same. DNS is refused too (it is a Unix socket and a Mach service on macOS). The approved command gets IP sockets, the resolver and the certificate checker (`com.apple.TrustEvaluationAgent`: without it the system `curl`, `git` and `python3` fail every `https://`, measured) and nothing else: secrets, sockets and the write rule stay. | net, dns, hostlocal, metadata, network for one approved command, the three "with the network on" |
| write/edit follow the write rule after resolving symlinks; read refuses hidden paths | Same functions over `F_GETPATH`. | the two F_GETPATH facts; the Linux unit tests port as they are |
| Without the sandbox the model's commands are refused; `AWL_SANDBOX=off`; `!cmd` is never sandboxed | Same. Nothing to install on macOS. | |

**Hold, and stronger than on Linux**

| Claim | Why stronger | Probes |
|---|---|---|
| Sockets under `/tmp` hidden two levels deep | Every Unix socket outside the project is refused at any depth, including `$TMPDIR` (editors keep IPC sockets there) and the ssh-agent socket under `/private/tmp/com.apple.launchd.*`. No scan at session start, so a socket created later is covered too. | tmpsock /tmp/S, tmpsock $TMPDIR/D/S, ssh-agent socket |
| Guarded project paths | A regex rule does not need the file to exist (Linux binds only what exists at session start), so a command cannot create a missing `AGENTS.md` or `.agents/`. By construction; not probed separately. Nested `AGENTS.md` files could be guarded the same way (a first version of the profile did, and the probe passed), but then `git clone`, `git checkout` or `tar x` of any tree containing one fails, so the profile guards the project's own only, as Linux does. | case: agents.md ...; a tree with its own AGENTS.md can be unpacked |
| `/run/user` (D-Bus, compositor, keyring sockets) | The macOS counterparts are Mach services, refused by name unless listed: Keychain, pasteboard, LaunchServices (`open`), Apple Events (`osascript`), TCC, the window server. Five services are allowed (user lookup, logging). | the seven "Mach service" lines, pbpaste, blocks starting a launchd job |

**Hold only with extra rules that Linux did not need** (all in `awl.sb`, all probed)

| Hole on macOS | Rule |
|---|---|
| **Rename around a path rule.** On Linux the guarded files are bind mounts, which cannot be moved. A path rule does not follow the file: `mv .git g; edit g/config; mv g .git`, or move the whole project to `/tmp` and back. | Deny unlink/rename of ROOT, `ROOT/.git` and `ROOT/.agents` themselves. Probes: the three "rename" / "move" lines. |
| **Case.** APFS is case-insensitive by default (this volume is). A *new* `agents.md` matches no literal `AGENTS.md` rule and is `AGENTS.md` to the next session. (Whether Seatbelt matches an existing file by its on-disk name was not separated out; `F_GETPATH` does.) The in-process `endsWith("/AGENTS.md")` has the same hole. | The four guards are regexes that accept any case; the in-process compare must ignore case on Darwin. Probe: "case: agents.md, .GIT/CONFIG, .git/HOOKS, .Agents". |
| **Other processes' environments.** `sysctl(KERN_PROCARGS2)` returns the arguments and environment of any process of the same user (unless it is one of Apple's own binaries): a command could read `GITHUB_TOKEN` out of a dev server started in another terminal. `(deny default)` does not stop it, and the first profile failed this probe. | Two rules, both needed (found by bisecting with `procargs.zig`). First, `process-info*` must be denied **by name** and given back for `(target same-sandbox)`: under `(version 1)` the default deny leaves it open. Second, `sysctl-read` must be a list of names: a bare `(allow sysctl-read)` lets the call through whatever `process-info` says. The list also leaves out `kern.proc.*`, which hides the process table. Probes: procenv, blocks listing other processes, a command reads its own child's arguments. `cc` crashes with no `sysctl-read` at all, so the list is needed, and it will need additions as tools turn up that read other names. |
| **awl's own key.** awl is such a process too: `AWL_KEY` sits in its environment block. The rules above cover it; this is the second lock. | awl copies the value and overwrites it in place at startup. `scrub.zig`: visible in `KERN_PROCARGS2` before, hidden after. |
| **`git init` inside a session.** A rule for a not-yet-existing `.git/hooks` makes `git init` fail. | Emit the `.git` guards only when `.git` exists at session start (what Linux does); keep the `AGENTS.md` and `.agents` guards always. |

**Change shape**

| Claim | On macOS |
|---|---|
| Sockets three levels deep under `/tmp` stay reachable; `AWL_SANDBOX_SOCKETS` names ones to keep (`docs/embedding.md`) | Reversed default: nothing is reachable unless named. An embedder that relies on depth (Hearth's `/tmp/hearth-awl-<id>/web/fetch.sock`) must pass `AWL_SANDBOX_SOCKETS`. A breaking difference for embedders; document it there. |
| Other processes are hidden | They are out of reach rather than absent, and the result is the same for the claims: their arguments and environments cannot be read, the process table cannot be listed, signals to them are refused (three probes). What changes is the tooling: `ps` and `top` do not run at all inside Seatbelt (setuid programs are refused) and `pgrep` fails (it needs a Mach service), even for a command's own processes. The model must be told (`jobs`, `kill %1`, `kill -0 pid` work), or it will burn steps on `ps aux \| grep`. |
| Commands cannot create user namespaces | Not applicable. The counterparts hold by construction: a sandbox cannot be removed or widened by the process inside it, a nested `sandbox-exec` is refused, and setuid programs (`sudo`, `ps`) do not run. |
| launchd | Read-only queries (`launchctl print`) answer: they go over the bootstrap port, which no profile can take away. Starting a job, which would run unsandboxed, is refused: inside, `launchctl submit` exits 1 and `bootstrap` fails with error 5, and no job runs; the same plist does start its job from outside (the probe's control). |
| "install bubblewrap" | Nothing to install. New failure: awl started inside another Seatbelt sandbox cannot sandbox its commands. |
| Tools that sandbox themselves | `swift build`, Chromium/Playwright, Bazel, Nix and `brew install` call `sandbox-exec` or `sandbox_init` and fail inside awl's sandbox (probe: refused). Each has an opt-out flag (`swift build --disable-sandbox`, `--no-sandbox`); the system prompt should say so on macOS. A real cost for Swift and browser-testing projects. |

**Cannot be met**

| Claim | Why |
|---|---|
| **Commands share a private localhost** | There is no network namespace: loopback is the host's loopback. Either commands get no IP sockets at all (then a dev server cannot even bind: probe "server bound: no"), or they reach whatever the host listens on (the model gateway on 12434, databases, Docker's TCP port). See 3.4. |

### 3.4 The localhost decision (decided 2026-11-14: B, reserved ports)

Three behaviours were probed; all three work as described.

| | Dev server reachable from the next command | Host's own localhost services | Model has to |
|---|---|---|---|
| **A. no IP sockets** (profile default) | no | unreachable | use Unix sockets in the project, or ask (`network: true`) |
| **B. a reserved port block** (`LOCAL=port`): bind and connect only on ports awl picked as free at session start, say 16 of them | yes, on those ports | unreachable | start servers on a given port (awl exports `PORT` and says so in the prompt) |
| **C. all of localhost** (`LOCAL=host`) | yes | **reachable** | nothing |

Decided: **B by default**, C behind `AWL_SANDBOX_NET=local` for people who want it. B keeps
the security claim and most of the function; its cost is that servers ignoring `$PORT` fail to
bind, and that is an arena question (does the model recover when `npm run dev` cannot take
3000?), so it gets a `arena/LOG.md` row before it becomes the default. A second process on the
host could also take one of the reserved ports later; awl only checks at session start.

### 3.5 Probe results from this Mac

`bash spike/macos/probes.sh`, macOS 27.2.1, Apple silicon, 2026-11-14. Each "blocks" line ran a
command under `awl.sb` that prints a marker only if it got through, and is counted only if the
command ran to its end; every outside target (the sockets, the host server, the process with
the secret) is first checked to answer outside the sandbox. `DIFF` lines are the shape changes
of 3.3. Exit status 0. (The first run of this suite had one `FAIL`, procenv; see 3.3.) `metadata` has no outside
control (nothing answers at 169.254.169.254 from this network); it rests on the same rule as `net`.

```
== network (README: no network unless you say yes) ==
ok    blocks net
ok    blocks dns (no lookups leave the machine)
ok    blocks hostlocal
ok    blocks metadata
ok    still works: network for one approved command (NET=on)
ok    blocks ssh keys with the network on
ok    blocks docker socket with the network on
ok    blocks write outside the project with the network on
== private localhost shared between commands ==
DIFF  a dev server started in the background is reachable from the next command: not by default (no IP sockets at all; server bound: no)
ok    still works: shared localhost on a reserved port (LOCAL=port)
ok    blocks hostlocal on other ports (LOCAL=port)
ok    blocks net (LOCAL=port)
DIFF  localhost is private (LOCAL=host): cannot be met: with all of localhost allowed, the host's own services are reachable
== sockets and services (README: /run/user, sockets under /tmp, the docker socket) ==
ok    blocks tmpsock /tmp/S
DIFF  sockets in /tmp reachable three levels deep (embedders rely on it): hidden at every depth; AWL_SANDBOX_SOCKETS must name each one
ok    blocks tmpsock $TMPDIR/D/S (editor IPC)
ok    blocks docker
skip  docker (/var/run/docker.sock): none on this machine
ok    blocks ssh-agent socket
ok    still works: a Unix socket of its own inside the project
ok    blocks Mach service Keychain
ok    blocks Mach service Keychain (xpc)
ok    blocks Mach service pasteboard
ok    blocks Mach service LaunchServices (open)
ok    blocks Mach service Apple Events (osascript)
ok    blocks Mach service TCC
ok    blocks Mach service window server
ok    blocks pbpaste reads the clipboard
ok    blocks launchd queries
ok    blocks starting a launchd job (it would run unsandboxed; submit=1 bootstrap=5 ; the same job starts outside)
== guarded project paths (.git/config, .git/hooks, AGENTS.md, .agents) ==
ok    blocks gitconfig
ok    blocks githooks
ok    blocks agentsmd
ok    blocks skills
ok    still works: a tree with its own AGENTS.md can be unpacked (nested ones are not guarded, as on Linux)
ok    blocks case: agents.md, .GIT/CONFIG, .git/HOOKS, .Agents
ok    blocks rename around the rule (mv .git g; edit; mv g .git)
ok    blocks rename .agents away and back
ok    blocks move the project to /tmp and back
ok    .git/config unchanged
ok    AGENTS.md unchanged
ok    .git/hooks unchanged
== writes (README: only the project, /tmp, build caches) ==
ok    blocks write to home
ok    blocks LaunchAgents (persistence)
ok    blocks symlink out of the project
ok    blocks hard link out of the project
ok    blocks dir symlink + .. (rootlink/..$HOME/x)
ok    file outside the project unchanged
ok    blocks session files: write
== reads (README: hidden paths) ==
ok    blocks sshbash
ok    blocks case: HOME/.SSH
ok    blocks symlink to a secret
ok    blocks hard link to a secret
ok    blocks HOME/Library app data (cookies, tokens)
ok    blocks HOME/Library/Keychains files
ok    blocks sessions
ok    blocks otherview
ok    still works: this session's view
== other processes (README: hidden; Linux uses a pid namespace) ==
DIFF  ps: does not run at all: Seatbelt refuses setuid programs (/bin/ps, top); pgrep does not work either
ok    blocks listing other processes
ok    blocks procenv (another process's environment)
ok    still works: a command reads its own child's arguments
ok    blocks signal to another process
DIFF  a later command stops an earlier command's background job: refused: each sandbox-exec is its own sandbox, so awl needs one sandboxed holder that starts every command
ok    still works: a command stops its own background job
DIFF  tools that sandbox themselves (swift build, Chromium, bazel, nix): fail inside: Seatbelt sandboxes do not nest
== environment (awl's own allowlist, sandbox.zig envOk: portable code, not Seatbelt) ==
ok    blocks env
== the toolchain still works ==
ok    still works: write in the project
ok    still works: /tmp
ok    still works: $TMPDIR (mktemp)
ok    still works: git add and commit
ok    still works: git status, log, diff
ok    still works: cc builds and runs a program
ok    still works: python3
ok    still works: ls -l (user names)
ok    still works: pipes, subshells, here-docs
ok    still works: rg
ok    still works: make
== facts the in-process rules (read/write/edit) rest on ==
ok    F_GETPATH returns the on-disk case: .SSH/ID_PROBE -> /.ssh/id_probe
ok    F_GETPATH resolves /tmp -> /private/tmp
note  this volume is case-insensitive: a new agents.md is AGENTS.md to the next session, so the guard must compare without case
== cost per command ==
plain /usr/bin/true:   Wall Time    722.7 µs  ±    81.0 µs     634.0 µs  …  1098.8 µs
under awl.sb:         Wall Time   7637.7 µs  ±  1610.8 µs    6805.8 µs  … 20598.8 µs          +956.8%  (10.6x slower)
probes: 71 ok, 0 FAIL, 6 DIFF, 1 skipped
```

What the probes do not cover: awl itself (the profile was driven by `sandbox-exec`, not by a
ported awl through `tests/fake_sse.py`); a real holder with awl's pipes and timeouts (`sbinit.zig`
shows the cost and that jobs can be stopped across commands, nothing more); an Intel Mac; a
case-sensitive volume; `/var/run/docker.sock` (none here; the same rule was probed on a socket
under a fake `~/.docker`); Xcode builds and Swift packages beyond one `cc`; how complete the
`sysctl` name list is for real projects (node, cargo, go and the JVM read names that one `cc`,
`git`, `make` and `python3` do not).

## 4. Tests and CI

**Runners.** `macos-15` (arm64) for test, check, e2e, sandbox and the release smoke test;
`macos-15-intel` for x86_64 (from memory: `macos-13`, the label in the plan, has been retired;
confirm both labels when the workflow is written). Add the newest image (`macos-26` or later) to the weekly
cron, since an OS update is where Seatbelt behaviour would change. Not verified here: that
`sandbox_init` works on GitHub's hosted macOS runners. Bazel and Codex run theirs there, so it
should; the first workflow run answers it. Linux CI is untouched: `link_libc` stays false
there and `tests/check.sh` keeps asserting "statically linked".

**What has to change in the scripts** (found by grep; macOS bash is 3.2.57, and no bash 4
syntax was found in `tests/*.sh`, so the first macOS run is the real check):

| Where | GNU-ism | Portable form |
|---|---|---|
| `build.zig` 79, 81, 86 | `timeout 20m` | Not in macOS 15's base system (this macOS 27 has `/usr/bin/timeout`). Drop the wrapper on Darwin and let the job's `timeout-minutes` do it, or `perl -e 'alarm 1200; exec @ARGV'`. |
| `tests/check.sh` 8 | `stat -c %s` | `wc -c <"$B"` |
| `tests/check.sh` 12 | `file ... 'statically linked'` | On Darwin assert `otool -L` lists only `/usr/lib/libSystem.B.dylib`. |
| `tests/check.sh` 15, `tests/peak.sh` | `--idle-rss`, `AWL_RSS` read `/proc/self/status` | No script change: `sys.rssKb` / `sys.peakRssKb` get Darwin implementations (`ru_maxrss` is bytes there). |
| `tests/e2e.sh` 235, 237, 254, 258, 281, 285, 764, 766 | `date +%s%N` (BSD `date` prints a literal `N`) | one helper: `now_ms() { python3 -c 'import time; print(time.monotonic_ns() // 1000000)'; }` |
| `tests/e2e.sh` 69 | `getent hosts` | Already inside an `if` that skips; on macOS `dscacheutil -q host -a name awl-e2e.test`, or keep the skip. |
| `tests/e2e.sh` 60 | looks for the Linux CA bundle paths | add `/etc/ssl/cert.pem` |
| `tests/sandbox.sh` 12 | `mktemp -d -p DIR` | `mktemp -d "DIR/tmp.XXXXXX"` (works on both) |
| `tests/sandbox.sh` 9, 49-53, 62, 100, 125 | `/usr/bin/bwrap`, `ip route`, `unshare`, `busctl`, `/run/user`, `find /tmp -type s`, `/proc/*/environ`, `ps -eo pgid=` | These are Linux claims, not spelling. A sibling **`tests/sandbox_macos.sh`** carries the macOS claims: `spike/macos/probes.sh` rewritten to drive a real awl through `tests/fake_sse.py`, so it also covers read/write/edit/grep and the holder. The Linux file stays Linux-only. |
| `tests/*.sh` 4-7 | `realpath` | In macOS since 13: fine on the runners above. |
| `tests/tui.py` | none (`pty`, `termios`, `fcntl` are portable) | Expect timing differences only. |
| `scripts/release.sh` 18 | already falls back to `shasum -a 256` | |
| `arena/*.sh` | `readlink -f`, `stat -c %Y`, `timeout`, `mktemp -p` | Out of scope: the arena runs on the Linux desktop. |

`zig build lint` stays a Linux job. It gains the rule from section 1: `std.os.linux` outside
`src/sys/linux.zig` and `src/sandbox/linux.zig` fails.

## 5. Go/no-go and plan

**Go**, for these reasons:

- The OS layer is mechanical. 276 of 459 uses are POSIX calls that exist under the same name;
  the five that need a Darwin answer all worked in the spike; the event loop needs no rewrite.
- libSystem costs 1.0 ms of startup and a 1.7 MB RSS floor, inside the 3 ms and 8 MB ceilings,
  and the Linux build stays static and libc-free.
- Seatbelt meets the claims that protect the user's machine: writes, secrets, network,
  guarded project files, Unix sockets, Mach services. The toolchain (git, cc, make, python,
  rg) works inside it. With the holder it costs nothing per command.
- The alternative, the rig, keeps Mac users in a Linux container, which is not the user
  experience the project aims at.

**Against, stated plainly:** it is not the same guarantee. One claim cannot be met as worded
(private localhost; reserved ports instead), `ps` is
gone, self-sandboxing tools break, and the mechanism is deprecated and undocumented. The
README must say each of these in a macOS paragraph; "same as Linux" would be false.

**Ship gates** (the port is not released until all are true):

1. The `procenv` probe passes through a ported awl (it passes under `sandbox-exec` today).
2. awl scrubs its own secrets from its environment block, with a test (`scrub.zig` shows it works).
3. `tests/sandbox_macos.sh` is green on both runners with zero skips, and red under the same
   mutation check thread A uses (remove one deny rule, expect a failure).
4. The localhost default has an arena row.

### Phases

Sizes are changed lines (added + removed), from the inventory. Each phase starts with its check.

| Phase | What | Check, written first | Size |
|---|---|---|---|
| 0. Seam (Linux only, after thread A lands) | Every `std.os.linux` use moves behind `sys.zig` into `src/sys/linux.zig`; `sandbox.zig` splits into shared rules and `sandbox/linux.zig`; one `Dir` iterator and one `stat`. No behaviour change. | New lint rule; Linux release bytes within 1% of before; `check`, `e2e`, `sandbox` green on both Linux arches. | ~1,100 (net +150) |
| 1. Darwin OS layer | `src/sys/darwin.zig` (~400 lines); `build.zig` (~25); `rg`/`fd` lookup, OS name, notifications, `/private/tmp` (~60); test scripts de-GNU'd (~40). | `zig build test` and `zig build e2e` on `macos-15` with `AWL_SANDBOX=off`; `zig build check` reports startup and RSS on macOS. | ~550 |
| 2. Sandbox | `src/sandbox/darwin.zig`: profile writer and holder (~450); in-process rule changes (~40); environment scrub (~20); `tests/sandbox_macos.sh` (~220). | `tests/sandbox_macos.sh`, starting from `spike/macos/probes.sh`; the four ship gates. | ~750 |
| 3. TUI, CI, release, docs | `tests/tui.py` on macOS; `ci.yml` matrix and weekly newest-image job (~40); `release.yml` and `scripts/release.sh` for `awl-macos-{aarch64,x86_64}` (~40); README Safety paragraph, settings rows, `docs/embedding.md` socket note, the three edits below. Delete `spike/macos/`. | Release smoke test on both macOS runners; arena `t0` on the Mac against the same model as Linux, one LOG row. | ~250 |
| | | | **~2,650** |

### The doc edits a "go" implies

`AGENTS.md` line 4, now:

    - Zig 0.16.0 via `mise`. Targets x86_64-linux-none and aarch64-linux-none (static, no libc). Std lib only.

becomes:

    - Zig 0.16.0 via `mise`. Targets x86_64-linux-none and aarch64-linux-none (static, no libc), and aarch64-macos and x86_64-macos (libSystem only: macOS has no stable syscall ABI). Std lib only. `std.os.linux` only in `src/sys/linux.zig` and `src/sandbox/linux.zig`.

`PLAN.md` line 8, the clause:

    Linux only (epoll and raw syscalls, no libc)

becomes (the code has never used epoll):

    Linux first (`poll` and raw syscalls, no libc), and macOS through libSystem since v1.x ([docs/macos-port.md](docs/macos-port.md))

`README.md` line 61, now:

    Spec and history: [PLAN.md](PLAN.md). Sibling project for macOS: `nib`.

becomes:

    Spec and history: [PLAN.md](PLAN.md). Runs on Linux and macOS; the macOS sandbox differs in a few places: see [Safety](#safety).

The same change also needs, in the README: a "macOS" paragraph at the end of Safety (the
"change shape" and "cannot be met" rows of 3.3), `/tmp` -> "`/tmp` and the per-user temp dir"
in the write rule, the `AWL_SANDBOX` and `AWL_SANDBOX_SOCKETS` rows (240, 244) and, if option B
is chosen, an `AWL_SANDBOX_NET=local` value in row 241.
