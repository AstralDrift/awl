"""The scheduler service."""
from svc.logging import log


def run(ctx):
    log("info", "scheduler step 1 of 2")
    log("warn", "scheduler step 2 of 2")
