"""The feeds service."""
from svc.logging import log


def run(ctx):
    log("warn", "feeds step 1 of 3")
    log(
        "error",
        f"feeds step 2 of 3 (n={ctx['n']})",
    )
    log("info", "feeds step 3 of 3")
