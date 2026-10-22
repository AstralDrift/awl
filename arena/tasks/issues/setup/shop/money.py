"""Money is kept in integer cents."""


def to_cents(text):
    """'12.50' -> 1250, '3' -> 300, '0.05' -> 5."""
    text = text.strip()
    if "." not in text:
        return int(text) * 100
    whole, frac = text.split(".", 1)
    frac = (frac + "00")[:2]
    return int(whole or "0") * 100 + int(frac)


def format_cents(cents):
    """1250 -> '12.50', 5 -> '0.05', -5 -> '-0.05'."""
    whole, rest = divmod(cents, 100)
    return f"{whole}.{rest:02d}"
