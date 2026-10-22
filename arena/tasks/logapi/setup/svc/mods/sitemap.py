"""The sitemap service."""
from svc.logging import log


def run(ctx):
    level = "warn" if ctx["n"] > 2 else "info"
    log(level, "sitemap step 1 of 2")
    log("warn", "sitemap step 2 of 2")
