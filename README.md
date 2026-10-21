# awl

A bare-metal coding-agent harness and inline TUI for Omarchy Linux. Written in Zig, static, no libc.
It talks to the Omarchy Local AI gateway (`127.0.0.1:12434`) and gives the model six tools:
read, write, edit, bash, grep (ripgrep), and find (fd).

Spec and build order: [PLAN.md](PLAN.md). Sibling project for macOS: `nib`.

    mise install          # pins Zig 0.16.0
    zig build -Doptimize=ReleaseSmall
    ./zig-out/bin/awl     # TUI
    ./zig-out/bin/awl -p "fix the failing test"

## Arena (benchmark against pi, omp, grok)

    python3 arena/run.py t0                          # awl only, no GPU: budgets + e2e
    python3 arena/run.py t1 --h "awl pi omp grok"    # 5 tasks, live model via Local AI
    python3 arena/run.py t2 --repeat 2               # 10 tasks x 2
    python3 arena/report.py [results.jsonl] [--accept]

Every harness goes through `arena/proxy.py`, which records turns, tokens, cached
tokens, bytes sent and model time per run. Tasks live in `arena/tasks/<id>/`
(`prompt.txt`, `setup/`, `check.sh`, hidden `solve.sh`); `arena/verify_tasks.sh`
proves each check fails unsolved and passes solved.
