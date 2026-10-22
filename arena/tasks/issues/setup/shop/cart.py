"""A cart of (product, quantity) lines with an optional percent coupon."""
from shop import tax


class Cart:
    def __init__(self, region="east"):
        self.lines = []
        self.coupon_percent = 0
        self.region = region

    def add(self, product, qty=1):
        self.lines.append((product, qty))

    def apply_coupon(self, percent):
        self.coupon_percent = percent

    def subtotal(self):
        total = 0
        for product, qty in self.lines:
            line = product.price_cents * qty
            if self.coupon_percent:
                line -= line * self.coupon_percent // 100
            total += line
            if self.coupon_percent:
                total -= total * self.coupon_percent // 100
        return total

    def total(self):
        sub = self.subtotal()
        return sub + tax.tax_for(self.region, sub)
