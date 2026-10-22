"""The stock service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"stock catalog: {items}")
    log("error", "stock step 1 of 4")
    log(
        "info",
        f"stock step 2 of 4 (n={ctx['n']})",
    )
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "stock step 3 of 4")
    log("error", "stock step 4 of 4")
