import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from billing.invoice import from_order  # noqa: E402
from billing.money import Money  # noqa: E402


class InvoiceTest(unittest.TestCase):
    def test_us_invoice(self):
        inv = from_order({"customer": "A", "region": "US", "currency": "USD",
                          "items": [{"sku": "widget", "qty": 2}, {"sku": "gizmo", "qty": 1, "discount": 10}]})
        self.assertEqual(inv.subtotal(), Money(14798, "USD"))
        self.assertEqual(inv.tax(), Money(1073, "USD"))
        self.assertEqual(str(inv.total()), "158.71 USD")

    def test_jpy_has_no_minor_units(self):
        inv = from_order({"customer": "A", "region": "JP", "currency": "JPY", "items": [{"sku": "gadget", "qty": 3}]})
        self.assertEqual(str(inv.total()), "2574 JPY")


if __name__ == "__main__":
    unittest.main()
