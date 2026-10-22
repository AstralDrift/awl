"""The coupons service."""
from svc.logging import log


def catalog(items):
    return sorted(items)


def run(ctx):
    items = catalog(["b", "a", "c"][: ctx["n"]])
    log("info", f"coupons catalog: {items}")
    log("info", "coupons step 1 of 2")
    log("warn", "coupons step 2 of 2")
