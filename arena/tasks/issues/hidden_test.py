"""Hidden checks, one or more per issue in ISSUES.md. Run from the task's work dir."""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.getcwd())
from shop.money import format_cents, to_cents  # noqa: E402
from shop.products import Product  # noqa: E402
from shop.cart import Cart  # noqa: E402
from shop import tax  # noqa: E402
from shop.inventory import Inventory, OutOfStock  # noqa: E402
from shop.csvio import load_products  # noqa: E402
from shop.dates import days_between  # noqa: E402
from shop.search import find  # noqa: E402
from shop.report import top_sellers  # noqa: E402

# 1 negative amounts
assert format_cents(-5) == "-0.05", format_cents(-5)
assert format_cents(-1250) == "-12.50", format_cents(-1250)
assert format_cents(0) == "0.00" and format_cents(1250) == "12.50" and format_cents(5) == "0.05"
assert to_cents("0.05") == 5 and to_cents("12.5") == 1250

# 2 coupon once on the subtotal
c = Cart()
for _ in range(3):
    c.add(Product("a", "A", 1000))
c.apply_coupon(10)
assert c.subtotal() == 2700, c.subtotal()
c2 = Cart()
c2.add(Product("a", "A", 1000), 3)
c2.apply_coupon(10)
assert c2.subtotal() == 2700, c2.subtotal()
c3 = Cart("north")
c3.add(Product("b", "B", 999), 1)
assert c3.total() == 999 + 100, c3.total()  # 99.9 -> 100

# 3 tax rounds half up, otherwise to nearest
assert tax.tax_for("north", 105) == 11, tax.tax_for("north", 105)
assert tax.tax_for("north", 104) == 10
assert tax.tax_for("north", 106) == 11, tax.tax_for("north", 106)
assert tax.tax_for("south", 1000) == 80 and tax.tax_for("east", 999) == 0
assert tax.tax_for("west", 125) == 15  # 15.0

# 4 no overselling
inv = Inventory({"x": 5})
try:
    inv.reserve("x", 6)
    raise AssertionError("reserve 6 of 5 did not raise")
except OutOfStock:
    pass
assert inv.available("x") == 5, inv.available("x")
assert inv.reserve("x", 5) == 0

# 5 quoted CSV fields
d = tempfile.mkdtemp()
p = os.path.join(d, "p.csv")
open(p, "w").write('sku,name,price\nA1,"Pens, blue",2.05\nA2,Plain,1\nA3,"Say ""hi""",0.5\n')
ps = load_products(p)
assert [(x.sku, x.name, x.price_cents) for x in ps] == [("A1", "Pens, blue", 205), ("A2", "Plain", 100), ("A3", 'Say "hi"', 50)], ps
out = subprocess.run([sys.executable, "-m", "shop", "products.csv", "pen"], capture_output=True, text=True)
assert out.returncode == 0 and "Pens, blue" in out.stdout, out.stdout + out.stderr

# 6 days between
assert days_between("2026-01-31", "2026-02-01") == 1
assert days_between("2028-02-28", "2028-03-01") == 2
assert days_between("2027-02-28", "2027-03-01") == 1
assert days_between("2025-12-31", "2026-12-31") == 365
assert days_between("2026-03-05", "2026-03-05") == 0

# 7 search
items = [Product("P1", "Notebook", 1), Product("P3", "Stapler", 2), Product("X", "Big NOTE pad", 3)]
assert [x.sku for x in find(items, "note")] == ["P1", "X"], find(items, "note")
assert [x.sku for x in find(items, "p3")] == ["P3"]
assert [x.sku for x in find(items, "")] == ["P1", "P3", "X"]

# 8 top sellers order
orders = [("b", 2), ("a", 2), ("c", 5), ("d", 1), ("a", 1), ("e", 3)]
assert top_sellers(orders, 3) == [("c", 5), ("a", 3), ("e", 3)], top_sellers(orders, 3)
assert top_sellers([("z", 1), ("y", 1)], 2) == [("y", 1), ("z", 1)]
print("hidden ok")
