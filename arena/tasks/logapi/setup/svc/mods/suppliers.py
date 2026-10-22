"""The suppliers service."""
from svc.logging import log


def run(ctx):
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "suppliers step 1 of 3")
    log("error", "suppliers step 2 of 3")
    log("info", "suppliers step 3 of 3")
