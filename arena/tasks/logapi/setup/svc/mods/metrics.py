"""The metrics service."""
from svc.logging import log


def run(ctx):
    log("error", "metrics step 1 of 4")
    log("info", "metrics step 2 of 4")
    log("warn", "metrics step 3 of 4")
    log("error", "metrics step 4 of 4")
