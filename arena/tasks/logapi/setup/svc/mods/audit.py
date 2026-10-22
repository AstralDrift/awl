"""The audit service."""
from svc.logging import log


def run(ctx):
    log("warn", "audit step 1 of 3")
    log("error", "audit step 2 of 3")
    log("info", "audit step 3 of 3")
