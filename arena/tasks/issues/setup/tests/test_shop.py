import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from shop.money import to_cents, format_cents  # noqa: E402
from shop.products import Product  # noqa: E402
from shop.cart import Cart  # noqa: E402


class ShopTest(unittest.TestCase):
    def test_to_cents(self):
        self.assertEqual(to_cents("12.50"), 1250)
        self.assertEqual(to_cents("3"), 300)

    def test_format(self):
        self.assertEqual(format_cents(1250), "12.50")

    def test_cart_without_coupon(self):
        c = Cart()
        c.add(Product("a", "A", 1000), 2)
        self.assertEqual(c.total(), 2000)


if __name__ == "__main__":
    unittest.main()
