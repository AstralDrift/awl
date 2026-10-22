"""The sms service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"sms catalog: {items}")
    log("warn", "sms step 1 of 3")
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "sms step 2 of 3")
    log("info", "sms step 3 of 3")
