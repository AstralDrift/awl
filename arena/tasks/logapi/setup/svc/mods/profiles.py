"""The profiles service."""
from svc.logging import log


def run(ctx):
    log(
        "warn",
        f"profiles step 1 of 3 (n={ctx['n']})",
    )
    log("error", "profiles step 2 of 3")
    log("info", "profiles step 3 of 3")
