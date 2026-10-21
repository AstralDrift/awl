# awl

A bare-metal coding-agent harness and inline TUI for Omarchy Linux. Written in Zig, static, no libc.
It talks to the Omarchy Local AI gateway (`127.0.0.1:12434`) and gives the model six tools:
read, write, edit, bash, grep (ripgrep), and find (fd).

Spec and build order: [PLAN.md](PLAN.md). Sibling project for macOS: `nib`.

    mise install          # pins Zig 0.16.0
    zig build -Doptimize=ReleaseSmall
    ./zig-out/bin/awl     # TUI
    ./zig-out/bin/awl -p "fix the failing test"
