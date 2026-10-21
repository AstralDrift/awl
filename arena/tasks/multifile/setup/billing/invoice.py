"""Invoice assembly."""
from dataclasses import dataclass, field

from billing import pricing, tax
from billing.money import zero


@dataclass
class Line:
    sku: str
    qty: int
    total: object


@dataclass
class Invoice:
    customer: str
    region: str
    code: str
    lines: list = field(default_factory=list)

    def add(self, sku, qty, discount_pct=0):
        self.lines.append(Line(sku, qty, pricing.line_total(sku, qty, self.code, discount_pct)))

    def subtotal(self):
        s = zero(self.code)
        for line in self.lines:
            s = s + line.total
        return s

    def tax(self):
        return tax.tax_for(self.subtotal(), self.region)

    def total(self):
        return self.subtotal() + self.tax()


def from_order(order):
    inv = Invoice(order["customer"], order["region"], order["currency"])
    for item in order["items"]:
        inv.add(item["sku"], item["qty"], item.get("discount", 0))
    return inv
