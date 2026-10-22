"""Date helpers (dates as 'YYYY-MM-DD')."""

DAYS = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def _parse(s):
    y, m, d = (int(x) for x in s.split("-"))
    return y, m, d


def days_between(a, b):
    """Whole days from a to b (b later): '2026-01-31', '2026-02-01' -> 1."""
    ya, ma, da = _parse(a)
    yb, mb, db = _parse(b)
    return (yb - ya) * 365 + (mb - ma) * 30 + (db - da)
