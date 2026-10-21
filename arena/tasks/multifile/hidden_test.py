import os
import sys
import unittest

sys.path.insert(0, os.getcwd())
from billing import currency  # noqa: E402
from billing.invoice import from_order  # noqa: E402
from billing.money import Money  # noqa: E402


class Hidden(unittest.TestCase):
    def test_eur(self):
        inv = from_order({"customer": "B", "region": "FR", "currency": "EUR",
                          "items": [{"sku": "gizmo", "qty": 3}, {"sku": "gadget", "qty": 1, "discount": 50}]})
        self.assertEqual(inv.subtotal(), Money(33245, "EUR"))
        self.assertEqual(str(inv.total()), "398.94 EUR")
        self.assertEqual(currency.exponent("EUR"), 2)
        self.assertEqual(currency.name("EUR"), "Euro")

    def test_others_unchanged(self):
        self.assertEqual(currency.exponent("JPY"), 0)
        self.assertEqual(currency.exponent("KWD"), 3)
        inv = from_order({"customer": "C", "region": "GB", "currency": "GBP", "items": [{"sku": "widget", "qty": 1}]})
        self.assertEqual(str(inv.total()), "19.20 GBP")
        inv = from_order({"customer": "D", "region": "DE", "currency": "EUR", "items": [{"sku": "widget", "qty": 2}, {"sku": "gadget", "qty": 10}]})
        self.assertEqual(str(inv.total()), "102.34 EUR")


if __name__ == "__main__":
    unittest.main()
