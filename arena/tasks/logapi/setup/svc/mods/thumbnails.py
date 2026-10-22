"""The thumbnails service."""
from svc.logging import log


def run(ctx):
    log("error", "thumbnails step 1 of 4")
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "thumbnails step 2 of 4")
    log("warn", "thumbnails step 3 of 4")
    log(
        "error",
        f"thumbnails step 4 of 4 (n={ctx['n']})",
    )
