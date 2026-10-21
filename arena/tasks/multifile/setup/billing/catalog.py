"""Product catalog: list prices are kept as decimal strings per currency."""
PRICES = {
    "widget": {"USD": "19.99", "EUR": "18.50", "GBP": "16.00", "JPY": "2900"},
    "gadget": {"USD": "5.25", "EUR": "4.90", "GBP": "4.20", "JPY": "780"},
    "gizmo": {"USD": "120.00", "EUR": "110.00", "GBP": "95.00", "JPY": "17500"},
}


def price(sku, code):
    try:
        return PRICES[sku][code]
    except KeyError:
        raise KeyError(f"no {code} price for {sku}") from None
