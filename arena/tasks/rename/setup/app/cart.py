from app.util import calc_total


def checkout(items):
    total = calc_total(items)
    return f"total={total}"
