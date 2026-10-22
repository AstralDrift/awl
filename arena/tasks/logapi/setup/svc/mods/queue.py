"""The queue service."""
from svc.logging import log


def run(ctx):
    log("error", "queue step 1 of 4")
    log("info", "queue step 2 of 4")
    log("warn", "queue step 3 of 4")
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "queue step 4 of 4")
