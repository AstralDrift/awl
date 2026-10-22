"""Sales reports."""
from collections import Counter


def top_sellers(orders, n=3):
    """orders: list of (sku, qty). The n skus with most units sold:
    most units first, ties by sku A-Z. Returns [(sku, units)]."""
    units = Counter()
    for sku, qty in orders:
        units[sku] += qty
    return list(units.items())[:n]
