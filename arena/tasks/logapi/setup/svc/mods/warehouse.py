"""The warehouse service."""
from svc.logging import log


def run(ctx):
    log(
        "info",
        f"warehouse step 1 of 2 (n={ctx['n']})",
    )
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "warehouse step 2 of 2")
