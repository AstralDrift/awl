from svc import cache, store


def compute_stats():
    orders = store.all_orders()
    return {
        "count": len(orders),
        "units": sum(o["qty"] for o in orders),
        "total": sum(o["qty"] * o["price"] for o in orders),
    }


def stats():
    return cache.cached("stats", compute_stats)
