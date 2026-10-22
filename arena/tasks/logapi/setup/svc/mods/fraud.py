"""The fraud service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"fraud catalog: {items}")
    log("warn", "fraud step 1 of 3")
    log("error", "fraud step 2 of 3")
    log("info", "fraud step 3 of 3")
