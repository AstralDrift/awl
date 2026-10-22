"""The sessions service."""
from svc.logging import log


def run(ctx):
    log("info", "sessions step 1 of 2")
    log(
        "warn",
        f"sessions step 2 of 2 (n={ctx['n']})",
    )
