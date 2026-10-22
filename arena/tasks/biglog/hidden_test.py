import os
import sys
from decimal import Decimal

sys.path.insert(0, os.getcwd())
from money.amounts import parse_amount  # noqa: E402

cases = {
    "12.345.678,90 EUR": ("12345678.90", "EUR"),
    "0,05 SEK": ("0.05", "SEK"),
    "1.000,00 CHF": ("1000.00", "CHF"),
    "999,99 EUR": ("999.99", "EUR"),
    "1,000 JPY": ("1000", "JPY"),
    "1,234.56 USD": ("1234.56", "USD"),
    "7.50 GBP": ("7.50", "GBP"),
}
for text, (v, c) in cases.items():
    got = parse_amount(text)
    assert got == (Decimal(v), c), f"hidden: {text!r} -> {got!r}"
print("hidden ok")
