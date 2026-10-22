"""The billing service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"billing catalog: {items}")
    log(
        "info",
        f"billing step 1 of 2 (n={ctx['n']})",
    )
    log("warn", "billing step 2 of 2")
