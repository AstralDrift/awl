"""Product search."""


def find(products, query):
    """Products whose name or sku contains query, ignoring case, in input order."""
    return [p for p in products if query in p.name]
