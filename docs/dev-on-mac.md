# Developing and using awl on a Mac

awl is a static Linux binary and does not build for macOS yet (a native port is being looked at in
`docs/macos-port.md`). Until then a Mac uses a Linux container: `rig/run.sh` cross-compiles awl on
the Mac and runs it, or its test suites, in an Ubuntu 24.04 image built from `rig/Dockerfile`.

Needs: Docker with a Linux VM (colima is what this was tested on) and Zig 0.16.0 (`mise install`).

## Using awl

    cd ~/some/project
    /path/to/awl/rig/run.sh shell

This builds awl for aarch64, builds the image if it is missing, and opens bash in the container as
the non-root user `tester`, with the current directory mounted at `/work` and `awl` on PATH. `AWL_*`
variables set on the Mac are passed in. awl's sandbox (bubblewrap) works there as on Linux.

- The directory must be one the Docker VM shares; colima shares your home directory by default.
  Elsewhere (macOS's `$TMPDIR` under `/var/folders`, say) the mount is not writable in the container.
- `AWL_URL` is resolved inside the container: `127.0.0.1` is the container, not the Mac. A server
  on the Mac is at `host.docker.internal` (under colima both that name and `host.lima.internal`
  resolve in the container), and has to listen on more than the Mac's loopback.
- The container is removed on exit. Sessions under `/home/tester` go with it; set
  `XDG_STATE_HOME=/work/.awl-state` (or similar) to keep them.

## Running the tests

    rig/run.sh                 # all: unit, check, e2e, sandbox
    rig/run.sh sandbox         # one or more of: unit check e2e sandbox
    rig/run.sh all --amd64     # the same on emulated x86_64

| Suite | Runs in the container |
|---|---|
| `unit` | the unit test binary (`zig test src/main.zig`, Debug, cross-compiled) |
| `check` | `tests/check.sh`: static, size, idle RSS, startup, peak RSS |
| `e2e` | `tests/e2e.sh` (with the TUI checks), `tests/embed.sh`, `arena/test_proxy.py` |
| `sandbox` | `tests/sandbox.sh`: the escape probes, through real bubblewrap; then `tests/nosandbox.sh`: what awl does when the sandbox is off or cannot start |

Each suite runs even if an earlier one failed; a summary with every suite's count ends the run, and
the exit code is non-zero if any failed. The suites run with `CI=true`, and a suite that prints a
`skip` line counts as failed, so
"sandbox passed" always means the probes ran. Logs are in `.zig-cache/rig/<arch>/`.

Each suite has a time limit, 20 minutes, or `RIG_TIMEOUT` seconds. It is kept on the Mac, which
kills the container: a suite that runs out is reported as "timed out", never left running.
One e2e check fails at random in roughly one run in four, on an unchanged binary too
(`rig/run.sh e2e` again before reading anything into it).

The image is tagged with a hash of `rig/Dockerfile`, so editing the Dockerfile rebuilds it. Old
`awl-rig:*` images are not removed (`docker image prune`, or `docker rmi`).

## What the numbers mean

- **aarch64 native** (the default). An Apple Silicon Mac runs the arm64 container without emulation,
  so startup, idle RSS and peak RSS are real measurements of the aarch64 binary, and the 3 ms / 8 MB
  ceilings in `tests/check.sh` apply. This matches CI's `ubuntu-24.04-arm` job, except that the unit
  tests here are a cross-compiled binary rather than `zig build test`.
- **emulated** (`--amd64`). The x86_64 binary under qemu. Size and "static" are exact; nothing else
  is a verdict. Measured on 2026-11-16 (617839c): idle RSS read 6.8 MB against 0.6 MB native; the
  unit test binary hung (the pidfd "background job holds the pipe" test) and was killed at the time
  limit; bubblewrap could not create a user namespace under qemu, so every check that runs a
  sandboxed command failed (sandbox 33/56, embed 18/25) for the rig's reason; hyperfine and the
  fake server's python3 crashed in the emulator and ended check and e2e early. Only `proxy` and
  `nosandbox` passed. Use it to see that the x86_64 binary starts and to read its size.
- **x86_64 runtime verdicts come from CI** (`ubuntu-24.04`): budgets, e2e and sandbox.

Every number the rig prints carries one of the two labels. Quote it with the label.

## Known limits

- **Zig does not run under emulation** (it segfaults under qemu/Rosetta in the amd64 container), so
  the rig always cross-compiles on the Mac. Zig in the image works on arm64 only.
- **bubblewrap needs unprivileged user namespaces in the VM's kernel.** colima's Ubuntu VM can have
  `kernel.apparmor_restrict_unprivileged_userns=1`, and bubblewrap then fails with "loopback: Failed
  RTM_NEWADDR". The rig reads the value first and stops with the line to run:

      colima ssh -- sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0

  The setting resets when the VM restarts. CI does the same on Ubuntu 24.04.
- **The container runs `--privileged`**, which bubblewrap needs inside Docker. It is a test rig and
  a stopgap, not a security boundary around awl itself: awl's own sandbox still confines the model's
  commands, but the container does not confine awl.
- **The sandbox tests need a non-root user with a real home**; that is `tester` in the image.
- **`tests/e2e.sh` needs `awl-e2e.test` to resolve**; the rig passes `--add-host awl-e2e.test:127.0.0.1`.
- **`zig build lint` and `zig build test` still run on the Mac directly** (lint is shell; the Debug
  unit tests are the `unit` suite here).

Under Claude Code's command sandbox:

- Zig cannot write `~/.cache`: set `ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global`.
- The Docker socket is not reachable: `rig/run.sh` needs the sandbox off.
- Use `/usr/bin/git`; a wrapper `git` on PATH can fail on a lock file.
