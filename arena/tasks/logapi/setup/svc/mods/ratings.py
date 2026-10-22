"""The ratings service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"ratings catalog: {items}")
    log("info", "ratings step 1 of 2")
    log("warn", "ratings step 2 of 2")
