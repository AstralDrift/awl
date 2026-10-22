"""The cache service."""
from svc.logging import log


def run(ctx):
    log(
        "warn",
        f"cache step 1 of 3 (n={ctx['n']})",
    )
    log("error", "cache step 2 of 3")
    log("info", "cache step 3 of 3")
