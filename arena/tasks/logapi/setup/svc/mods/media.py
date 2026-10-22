"""The media service."""
from svc.logging import log


def run(ctx):
    log("warn", "media step 1 of 3")
    log("error", "media step 2 of 3")
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "media step 3 of 3")
