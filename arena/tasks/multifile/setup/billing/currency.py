"""Currency metadata loaded from data/currencies.csv."""
import os

_PATH = os.path.join(os.path.dirname(__file__), "data", "currencies.csv")
_TABLE = None


def _load():
    table = {}
    with open(_PATH) as f:
        next(f)  # header
        for line in f:
            code, minor, name = line.rstrip("\n").split(",")
            table[code] = (int(minor), name)
    return table


def table():
    global _TABLE
    if _TABLE is None:
        _TABLE = _load()
    return _TABLE


def exponent(code):
    """Number of minor-unit digits (2 for cents). Unknown currencies have none."""
    return table().get(code, (0, code))[0]


def name(code):
    return table().get(code, (0, code))[1]
