"""Parse human-written amounts like '1,234.56 USD' or '12,50 EUR' into (Decimal, code)."""
from decimal import Decimal

COMMA_DECIMAL = {"EUR", "SEK", "CHF"}  # these write 12,50 for twelve and a half


def parse_amount(text):
    num, code = text.strip().rsplit(" ", 1)
    if code in COMMA_DECIMAL and "," in num:
        num = num.replace(",", ".")
    else:
        num = num.replace(",", "")
    return Decimal(num), code
