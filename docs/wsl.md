# awl on WSL

awl is a Linux program, so on Windows it runs inside Windows Subsystem for Linux. The aim is that
WSL2 runs the same sandbox as any Linux machine, plus masks for the ways out that only WSL has
(Windows programs, the Windows drives, WSLg). This page says what is tested, how, and what is not.

## Status

**Not yet run on a real WSL machine.** `tests/wsl.sh` and `.github/workflows/wsl.yml` exist and
lint clean; the script's plumbing was run once on Linux against a faked WSL surface (a stand-in
`cmd.exe`, a socket in `/run/WSL`, a bind of `/` at `/mnt/wslg/distro`), which proves the verdict
logic and nothing about WSL. The table under "Results" is empty until the workflow's first run.
Until then the README's advice for WSL (`AWL_SANDBOX=off`) stands.

Read from the code (`src/sandbox.zig`), not yet measured, these are expected to get through today:

- `--ro-bind / /` is recursive, so `/mnt/c`, `/run/WSL` and `/mnt/wslg` are all inside the sandbox.
- A Unix socket with a path is reachable from a private network namespace, so `/run/WSL/*_interop`
  can still start `cmd.exe`: a Windows process, outside the sandbox, with the network.
- `/mnt/wslg/distro` is a second view of the whole distro; the tmpfs over `~/.ssh` does not cover
  `/mnt/wslg/distro/home/<you>/.ssh`.
- `PATH` is on the environment allowlist and WSL appends the Windows `PATH` to it.
- The read and grep tools hide secrets under `$HOME` only, not under `/mnt/c/Users/<you>`.

## Setup

WSL2 (WSL1 cannot run the sandbox: it has no user namespaces):

```sh
wsl.exe -l -v                       # in Windows: VERSION must be 2
wsl.exe --set-version <distro> 2    # if it is 1
sudo apt install bubblewrap ripgrep fd-find   # in the distro
```

Whether bubblewrap then works with nothing else enabled is the first thing the workflow records
("bubblewrap out of the box"); this section gets the answer after the first run.

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
| `wslg-sock`, `wslg-x11` | a socket under `/mnt/wslg`, or in `/tmp/.X11-unix`, accepts a connection |
| `tool-read-drvfs`, `tool-grep-drvfs`, `tool-write-drvfs` | awl's own read, grep and write tools reach the planted files on the Windows drive |
| `wslg-tool-read` | the read tool returns `~/.ssh` through `/mnt/wslg/distro` |
| controls | commands still write in the project; a project on the Windows drive still works and cannot write next to itself; `tests/tui.py` passes |
| WSL1 | the model's command does not run; the refusal names WSL1 |

## Results

None yet (see Status). After a run: the job summary of each matrix leg has the facts of that WSL
(kernel, `wsl.conf`, mounts, `/run/WSL`, `/mnt/wslg`) and the result block of `tests/wsl.sh`.

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
- A Windows Server runner has no desktop session, so WSLg is likely absent there: `wslg-*` and
  `env-wslg` end `untested` on CI. Untested is not passed; a by-hand run on Windows 11 covers them.
- `tests/tui.py` opens its own Linux pty. It checks the TUI on the WSL kernel, not through conpty
  or Windows Terminal (key encoding, CRLF paste, resize on the Windows side).
- Startup time is not checked on WSL.
- One distro (Ubuntu-24.04), default `wsl.conf` (interop on, Windows `PATH` appended, drives
  auto-mounted under `/mnt`). A custom `automount.root`, mirrored networking, or drives mounted
  elsewhere are not covered; the drive probes look under `/mnt/<letter>` only.
- The workflow starts on changes to its own three files. A sandbox change does not start it:
  dispatch it by hand on that branch (possible once `wsl.yml` is on `main`; before that, the
  branch has to contain these files and touch one of them).
