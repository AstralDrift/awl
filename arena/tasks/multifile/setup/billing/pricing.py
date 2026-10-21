"""Turns order lines into priced lines."""
from billing import catalog
from billing.money import Money


def unit_price(sku, code):
    return Money.parse(catalog.price(sku, code), code)


def line_total(sku, qty, code, discount_pct=0):
    total = unit_price(sku, code).scale(qty)
    if discount_pct:
        total = total.scale((100 - discount_pct) / 100)
    return total
