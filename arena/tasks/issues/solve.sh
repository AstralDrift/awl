#!/bin/sh
python3 - <<'P'
import re
def sub(p, a, b):
    s = open(p).read(); assert a in s, (p, a); open(p, "w").write(s.replace(a, b))
sub("shop/money.py", '''    whole, rest = divmod(cents, 100)
    return f"{whole}.{rest:02d}"''', '''    sign = "-" if cents < 0 else ""
    whole, rest = divmod(abs(cents), 100)
    return f"{sign}{whole}.{rest:02d}"''')
sub("shop/cart.py", '''            line = product.price_cents * qty
            if self.coupon_percent:
                line -= line * self.coupon_percent // 100
            total += line
            if self.coupon_percent:
                total -= total * self.coupon_percent // 100
        return total''', '''            total += product.price_cents * qty
        if self.coupon_percent:
            total -= total * self.coupon_percent // 100
        return total''')
sub("shop/tax.py", "    return int(cents * rate / 100)", "    return (cents * rate + 50) // 100")
sub("shop/inventory.py", "        if n > have + 1:", "        if n > have:")
sub("shop/csvio.py", '''"""Load products from CSV: sku,name,price."""''', '''"""Load products from CSV: sku,name,price."""
import csv''')
sub("shop/csvio.py", '''        for line in f:
            line = line.strip()
            if not line:
                continue
            sku, name, price = line.split(",")''', '''        for row in csv.reader(f):
            if not row:
                continue
            sku, name, price = row''')
sub("shop/dates.py", '''    ya, ma, da = _parse(a)
    yb, mb, db = _parse(b)
    return (yb - ya) * 365 + (mb - ma) * 30 + (db - da)''', '''    import datetime
    return (datetime.date(*_parse(b)) - datetime.date(*_parse(a))).days''')
sub("shop/search.py", "    return [p for p in products if query in p.name]", """    q = query.lower()
    return [p for p in products if q in p.name.lower() or q in p.sku.lower()]""")
sub("shop/report.py", "    return list(units.items())[:n]", "    return sorted(units.items(), key=lambda kv: (-kv[1], kv[0]))[:n]")
t = open("tests/test_shop.py").read()
t = t.replace('if __name__ == "__main__":', """class IssueTest(unittest.TestCase):
    def test_1_negative(self):
        self.assertEqual(format_cents(-5), "-0.05")

    def test_2_coupon(self):
        c = Cart()
        c.add(Product("a", "A", 1000), 3)
        c.apply_coupon(10)
        self.assertEqual(c.subtotal(), 2700)

    def test_3_tax(self):
        from shop.tax import tax_for
        self.assertEqual(tax_for("north", 105), 11)

    def test_4_stock(self):
        from shop.inventory import Inventory, OutOfStock
        with self.assertRaises(OutOfStock):
            Inventory({"x": 5}).reserve("x", 6)

    def test_5_csv(self):
        from shop.csvio import load_products
        self.assertEqual(load_products("products.csv")[1].name, "Pens, blue")

    def test_6_days(self):
        from shop.dates import days_between
        self.assertEqual(days_between("2026-01-31", "2026-02-01"), 1)

    def test_7_search(self):
        from shop.search import find
        self.assertEqual(len(find([Product("P3", "Notebook", 1)], "p3")), 1)

    def test_8_top(self):
        from shop.report import top_sellers
        self.assertEqual(top_sellers([("b", 1), ("a", 1)], 2), [("a", 1), ("b", 1)])


if __name__ == "__main__":""")
open("tests/test_shop.py", "w").write(t)
P
