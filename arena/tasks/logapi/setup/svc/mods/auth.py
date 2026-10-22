"""The auth service."""
from svc.logging import log


def run(ctx):
    log("info", "auth step 1 of 2")
    log("warn", "auth step 2 of 2")
