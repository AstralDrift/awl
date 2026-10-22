import sys

from shop.csvio import load_products
from shop.money import format_cents
from shop.search import find

if __name__ == "__main__":
    products = load_products(sys.argv[1])
    for p in find(products, sys.argv[2] if len(sys.argv) > 2 else ""):
        print(f"{p.sku}  {p.name}  {format_cents(p.price_cents)}")
