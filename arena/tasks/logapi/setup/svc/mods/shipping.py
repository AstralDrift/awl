"""The shipping service."""
from svc.logging import log


def run(ctx):
    log("warn", "shipping step 1 of 3")
    log("error", "shipping step 2 of 3")
    log("info", "shipping step 3 of 3")
