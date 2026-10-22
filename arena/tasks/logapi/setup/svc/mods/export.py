"""The export service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"export catalog: {items}")
    log("error", "export step 1 of 4")
    log("info", "export step 2 of 4")
    log(
        "warn",
        f"export step 3 of 4 (n={ctx['n']})",
    )
    log("error", "export step 4 of 4")
