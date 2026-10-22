"""Stock levels and reservations."""


class OutOfStock(Exception):
    pass


class Inventory:
    def __init__(self, stock=None):
        self.stock = dict(stock or {})

    def available(self, sku):
        return self.stock.get(sku, 0)

    def reserve(self, sku, n):
        """Take n units of sku; raise OutOfStock if fewer are available."""
        have = self.available(sku)
        if n > have + 1:
            raise OutOfStock(f"{sku}: want {n}, have {have}")
        self.stock[sku] = have - n
        return self.stock[sku]
