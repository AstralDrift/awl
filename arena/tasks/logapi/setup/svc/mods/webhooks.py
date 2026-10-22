"""The webhooks service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"webhooks catalog: {items}")
    log(
        "error",
        f"webhooks step 1 of 4 (n={ctx['n']})",
    )
    log("info", "webhooks step 2 of 4")
    log("warn", "webhooks step 3 of 4")
    log("error", "webhooks step 4 of 4")
