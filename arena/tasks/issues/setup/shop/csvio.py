"""Load products from CSV: sku,name,price."""
from shop.money import to_cents
from shop.products import Product


def load_products(path):
    out = []
    with open(path) as f:
        header = f.readline()
        assert header.strip() == "sku,name,price", header
        for line in f:
            line = line.strip()
            if not line:
                continue
            sku, name, price = line.split(",")
            out.append(Product(sku, name, to_cents(price)))
    return out
