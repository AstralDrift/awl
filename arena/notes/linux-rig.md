# Offline rig on a Mac (2026-10-30)

awl targets x86_64-linux-none. On an Apple Silicon Mac the offline suite runs like this:

    mise exec -- zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux       # the binary (356,480 B at 8d7c9ae)
    mise exec -- zig test src/main.zig -target x86_64-linux -OReleaseSafe --test-no-exec -femit-bin=zig-out/awl-test
    docker build --platform linux/amd64 -t awl-linux:dev arena/notes/linux-rig/   # Debian + bwrap, rg, fd, hyperfine, python3
    docker run --rm --privileged --platform linux/amd64 -v "$PWD":/work -w /work awl-linux:dev bash -c '
      zig-out/awl-test; AWL_SANDBOX=off bash tests/e2e.sh zig-out/bin/awl; sh tests/check.sh zig-out/bin/awl'

Limits, so numbers from here are labelled "emulated":
- Zig itself segfaults under Rosetta/qemu in the container, so everything is cross-compiled on the Mac.
- Startup and RSS are inflated by emulation (idle RSS 6.5 MB vs 0.4 MB on the desktop; check.sh's
  3 ms startup ceiling is not meaningful). Size is exact.
- bubblewrap cannot create user namespaces inside the colima VM (Ubuntu kernel,
  `kernel.apparmor_restrict_unprivileged_userns=1`), so tests/sandbox.sh and the sandbox-dependent e2e
  checks (network approval, guarded AGENTS.md, background agents) fail for the rig's reason, not awl's.
  `colima ssh -- sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` would fix it for the VM's
  lifetime (CI does the same on Ubuntu 24.04); it was not run from the agent session.
- Baseline at 8d7c9ae: unit 69/70 (the pidfd "background job holds the pipe" test fails under emulation),
  e2e 50/51 with AWL_SANDBOX=off, check: static, size 356,480 B.
