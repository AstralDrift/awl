# awl on WSL

awl is a Linux program, so on Windows it runs inside Windows Subsystem for Linux. The aim is that
WSL2 runs the same sandbox as any Linux machine, plus masks for the ways out that only WSL has
(Windows programs, the Windows drives, WSLg). This page says what is tested, how, and what is not.

## Status

Run once on real WSL: GitHub-hosted `windows-2025`, WSL 3.0.3.0, Ubuntu-24.04, 2026-11-14
(the first run of PR 28; awl `3142d34`, a release build of that PR merged into `main` at
`75be427`, so `src/` is main's).

- **WSL2 runs the real sandbox.** Kernel `6.18.54.1-microsoft-standard-WSL2`. bubblewrap 0.9.0
  works with nothing enabled; `tests/e2e.sh` 68 passed, `tests/sandbox.sh` 38 passed,
  `tests/check.sh` passed (peak RSS 1580 KB, idle 716 KB; startup not measured).
- **The sandbox has WSL-only holes: 15 of 22 probes got through** (table under Results). The
  worst: a sandboxed command that sets `WSL_INTEROP` to a socket in `/run/WSL` runs `cmd.exe`, a
  Windows process outside the sandbox with the network. Until `src/sandbox.zig` masks these,
  treat awl's sandbox on WSL2 as protecting the Linux side only.
- **WSL1 fails closed** (second run, kernel `4.4.0-26100-Microsoft`): the model's command is
  refused with bubblewrap's own error ("Creating new namespace failed..."), which does not say
  that WSL1 is the reason or what to do.
- **Fix, not yet proven on WSL:** the masks proposed under Results are in `src/sandbox.zig` on
  this branch (tmpfs over `/run/WSL`, `/mnt/wslg` and the drvfs drives; the read tool refuses
  the same paths; Windows folders dropped from `PATH`; a WSL1 refusal that names WSL1). On Linux
  with a faked WSL surface the `/run/WSL` and `/mnt/wslg` half holds; the drive mask can only be
  judged by the next WSL run. This page is updated from that run.

## Setup

WSL2 (WSL1 cannot run the sandbox: it has no user namespaces):

```sh
wsl.exe -l -v                       # in Windows: VERSION must be 2
wsl.exe --set-version <distro> 2    # if it is 1
sudo apt install bubblewrap ripgrep fd-find   # in the distro
```

Nothing else. On the tested Ubuntu-24.04 distro (`systemd=true` in `/etc/wsl.conf`, as shipped)
bubblewrap worked as a non-root user out of the box: the WSL kernel has no AppArmor limit on
user namespaces, so the `sysctl kernel.apparmor_restrict_unprivileged_userns=0` that Ubuntu 24.04
needs on bare metal is not needed here.

## What is tested

`.github/workflows/wsl.yml`, on a GitHub-hosted `windows-2025` runner, with `Vampire/setup-wsl`
installing Ubuntu-24.04 once as WSL2 and once as WSL1. It first asserts the version (`wsl.exe -l
-v` and `uname -r`), then, as a non-root user, on the release binary (`zig build release`), with
the tree on the distro's own disk:

| Step | WSL2 | WSL1 |
|---|---|---|
| bubblewrap with awl's base flags, nothing enabled first | yes | no |
| `tests/check.sh` (static, idle RSS, 8 MB peak; no hyperfine, so the 3 ms startup ceiling is skipped) | yes | no |
| `tests/e2e.sh` (includes `tests/tui.py`) | yes | no |
| `tests/sandbox.sh`, unchanged | yes | no |
| `tests/wsl.sh` | escape probes | fail-closed check |

`tests/wsl.sh` runs every probe twice through awl's real tools: once with `AWL_SANDBOX=off` (can
this machine show the escape at all?) and once sandboxed. A probe is `blocked` only if it fired
unsandboxed and not in the sandbox; `ESCAPED` if it fired in the sandbox; `untested` if it fired
in neither. Every probe must also run to its end in the sandbox, or it counts as failed.
Exit 0 nothing escaped, 1 an escape or a failed control, 2 not WSL, 3 a probe named in
`WSL_REQUIRE` was untested.

| Probe | What firing means |
|---|---|
| `interop-cmd` | `cmd.exe` (full path) runs and prints Windows output |
| `interop-sock` | the same after the command sets `WSL_INTEROP` to a socket in `/run/WSL` itself |
| `init-interop` | `/init`, the binfmt_misc handler, starts `cmd.exe` when called directly |
| `interop-powershell` | `powershell.exe` runs |
| `interop-connect` | a socket in `/run/WSL` accepts a connection |
| `interop-runwsl` | `/run/WSL` can be listed |
| `env-interop`, `env-wslg` | `WSL_INTEROP`, or `DISPLAY`/`WAYLAND_DISPLAY`/`PULSE_SERVER`, reach the command |
| `winpath`, `winpath-exec` | `PATH` has `/mnt/<drive>/...` folders; a Windows program is found by bare name |
| `drvfs-read`, `drvfs-write` | a planted file on the Windows drive is read; a file there is written |
| `drvfs-ssh`, `drvfs-aws`, `drvfs-appdata` | `.ssh`, `.aws`, `AppData\Local` of a Windows profile can be listed |
| `wslg-distro` | `~/.ssh` is read through `/mnt/wslg/distro` |
| `wslg-sock`, `wslg-x11` | a socket under `/mnt/wslg` (also under `/mnt/wslg/run/user`), or in `/tmp/.X11-unix`, accepts a connection |
| `wslg-runuser` | `/run/user/<uid>` can be listed through `/mnt/wslg/run/user` |
| `tool-read-drvfs`, `tool-grep-drvfs`, `tool-write-drvfs` | awl's own read, grep and write tools reach the planted files on the Windows drive |
| `wslg-tool-read` | the read tool returns `~/.ssh` through `/mnt/wslg/distro` |
| controls | commands still write in the project; a project on the Windows drive still works and cannot write next to itself; `tests/tui.py` passes |
| WSL1 | the model's command does not run; the refusal names WSL1 |

## Results

WSL2, 2026-11-14, hosted `windows-2025` (WSLg was present: 6 sockets under `/mnt/wslg`):

| Probe | Verdict |
|---|---|
| `interop-cmd`, `interop-powershell` | blocked (see note) |
| `interop-sock` | **ESCAPED** |
| `init-interop` | **ESCAPED** |
| `interop-connect` | **ESCAPED** (`/run/WSL/1_interop`, `2_interop`, `<pid>_interop`) |
| `interop-runwsl` | **ESCAPED** |
| `env-interop`, `env-wslg` | blocked |
| `winpath`, `winpath-exec` | **ESCAPED** (73 Windows folders on `PATH`) |
| `drvfs-read` | **ESCAPED** |
| `drvfs-write` | blocked |
| `drvfs-ssh`, `drvfs-aws`, `drvfs-appdata` | **ESCAPED** |
| `wslg-distro` | **ESCAPED** |
| `wslg-sock` | **ESCAPED** (`PulseServer`, `PulseAudioRDPSink`, `PulseAudioRDPSource`, `.X11-unix/X0` under `/mnt/wslg`) |
| `wslg-x11` | blocked |
| `tool-read-drvfs`, `tool-grep-drvfs` | **ESCAPED** |
| `tool-write-drvfs` | blocked |
| `wslg-tool-read` | **ESCAPED** |
| controls (write in the project, project on `/mnt/c`, no write next to it) | ok |
| `tests/tui.py` | ok, 152 checks |

Note on `interop-cmd`: running `cmd.exe` by path fails in the sandbox only because the command
has no `WSL_INTEROP` and `/init` cannot find its socket from inside the pid namespace. Setting
the variable to any socket in `/run/WSL` (`interop-sock`) is enough, so this is not a defence.

WSL1: no result yet.

The job summary of each matrix leg has the facts of that WSL (kernel, `wsl.conf`, mounts,
`/run/WSL`, `/mnt/wslg`) and the result block of `tests/wsl.sh`.

## Running it by hand

On any WSL machine, with an awl binary:

```sh
bash tests/wsl.sh path/to/awl
```

It needs `bubblewrap` and `python3`. It creates one folder `awl-wsl-probe-<pid>` under
`C:\Users\Public` (or your Windows profile if that is not writable), reads and writes only files
it planted, and removes them. It lists, without reading, `.ssh`, `.aws` and `AppData\Local` of
Windows profiles if they exist; `WSL_PLANT_HOME=1` additionally plants one probe file in your
profile's `.ssh` and `.aws` so those probes cannot end untested. The run with `AWL_SANDBOX=off`
executes `cmd.exe /c "echo %OS%"` and `powershell.exe -Command '$env:OS'` for real. The block
between `----- awl wsl result` and `----- end -----` is made to be pasted into an issue: Windows
user names are replaced by `<user>`.

## Limits

- GitHub Actions is the only WSL the project can reach; nobody ran this on a Windows desktop.
  If hosted runners stop offering WSL2, the first step fails and says so: dispatch the workflow
  with a self-hosted runner label (the `runner` input) or run the script by hand.
- WSLg was present on the hosted runner, so the `wslg-*` probes ran. No desktop app was open
  there; what a connected X11 or Wayland client can do to a real desktop session was not tried.
- `tests/tui.py` opens its own Linux pty. It checks the TUI on the WSL kernel, not through conpty
  or Windows Terminal (key encoding, CRLF paste, resize on the Windows side).
- Startup time is not checked on WSL.
- Not probed: Hyper-V sockets (`AF_VSOCK`/hvsocket) from inside the sandbox, `/mnt/wsl` (the
  tmpfs WSL shares between distros), and drives mounted outside `/mnt/<letter>`.
- One distro (Ubuntu-24.04), default `wsl.conf` (interop on, Windows `PATH` appended, drives
  auto-mounted under `/mnt`). A custom `automount.root`, mirrored networking, or drives mounted
  elsewhere are not covered; the drive probes look under `/mnt/<letter>` only.
- The workflow starts on changes to its own three files. A sandbox change does not start it:
  dispatch it by hand on that branch (possible once `wsl.yml` is on `main`; before that, the
  branch has to contain these files and touch one of them).
