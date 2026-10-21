"""Money as integer minor units."""
from dataclasses import dataclass
from decimal import ROUND_HALF_EVEN, Decimal

from billing import currency


@dataclass(frozen=True)
class Money:
    minor: int
    code: str

    @staticmethod
    def parse(text, code):
        """'12.34' EUR -> Money(1234, 'EUR')."""
        return Money(to_minor(Decimal(text), code), code)

    def __add__(self, other):
        assert self.code == other.code, (self.code, other.code)
        return Money(self.minor + other.minor, self.code)

    def scale(self, factor):
        q = (Decimal(self.minor) * Decimal(factor)).quantize(Decimal(1), rounding=ROUND_HALF_EVEN)
        return Money(int(q), self.code)

    def major(self):
        return Decimal(self.minor).scaleb(-currency.exponent(self.code))

    def __str__(self):
        e = currency.exponent(self.code)
        return f"{self.major():.{e}f} {self.code}"


def to_minor(amount, code):
    q = (Decimal(amount).scaleb(currency.exponent(code))).quantize(Decimal(1), rounding=ROUND_HALF_EVEN)
    return int(q)


def zero(code):
    return Money(0, code)
