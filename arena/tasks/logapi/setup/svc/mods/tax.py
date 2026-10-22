"""The tax service."""
from svc.logging import log


def run(ctx):
    log("warn", "tax step 1 of 3")
    log(
        "error",
        f"tax step 2 of 3 (n={ctx['n']})",
    )
    log("info", "tax step 3 of 3")
