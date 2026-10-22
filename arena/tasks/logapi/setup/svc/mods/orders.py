"""The orders service."""
from svc.logging import log


def run(ctx):
    log("error", "orders step 1 of 4")
    log("info", "orders step 2 of 4")
    log("warn", "orders step 3 of 4")
    log("error", "orders step 4 of 4")
