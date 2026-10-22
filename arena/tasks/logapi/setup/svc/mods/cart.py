"""The cart service."""
from svc.logging import log


def run(ctx):
    log("warn", "cart step 1 of 3")
    log("error", "cart step 2 of 3")
    log("info", "cart step 3 of 3")
