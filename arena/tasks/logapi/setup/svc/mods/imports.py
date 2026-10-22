"""The imports service."""
from svc.logging import log


def run(ctx):
    log("info", "imports step 1 of 2")
    log(
        "warn",
        f"imports step 2 of 2 (n={ctx['n']})",
    )
