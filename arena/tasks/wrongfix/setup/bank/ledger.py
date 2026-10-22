"""Balances from signed transactions."""
from decimal import Decimal


def balance(txs, account):
    total = Decimal("0")
    for t in txs:
        if t.account != account:
            continue
        if t.kind == "refund":
            total -= abs(t.amount)  # refunds reduce what the customer owes us... see importer
        else:
            total += t.amount
    return total
