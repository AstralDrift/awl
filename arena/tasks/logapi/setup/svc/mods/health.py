"""The health service."""
from svc.logging import log


def run(ctx):
    log("info", "health step 1 of 2")
    log("warn", "health step 2 of 2")
