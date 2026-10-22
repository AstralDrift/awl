"""The backup service."""
from svc.logging import log


def run(ctx):
    log("warn", "backup step 1 of 3")
    log("error", "backup step 2 of 3")
    log("info", "backup step 3 of 3")
