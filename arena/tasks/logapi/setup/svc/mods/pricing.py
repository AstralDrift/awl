"""The pricing service."""
from svc.logging import log


def run(ctx):
    log(
        "error",
        f"pricing step 1 of 4 (n={ctx['n']})",
    )
    log("info", "pricing step 2 of 4")
    log("warn", "pricing step 3 of 4")
    log("error", "pricing step 4 of 4")
