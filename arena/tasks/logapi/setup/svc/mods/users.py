"""The users service."""
from svc.logging import log


def run(ctx):
    log("error", "users step 1 of 4")
    log("info", "users step 2 of 4")
    log(
        "warn",
        f"users step 3 of 4 (n={ctx['n']})",
    )
    log("error", "users step 4 of 4")
