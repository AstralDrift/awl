"""The refunds service."""
from svc.logging import log


def run(ctx):
    log("warn", "refunds step 1 of 3")
    log("error", "refunds step 2 of 3")
    log(
        "info",
        f"refunds step 3 of 3 (n={ctx['n']})",
    )
