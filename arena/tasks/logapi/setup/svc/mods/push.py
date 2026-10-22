"""The push service."""
from svc.logging import log


def run(ctx):
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "push step 1 of 4")
    log("info", "push step 2 of 4")
    log("warn", "push step 3 of 4")
    log(
        "error",
        f"push step 4 of 4 (n={ctx['n']})",
    )
