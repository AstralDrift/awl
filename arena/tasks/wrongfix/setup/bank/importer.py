"""Reads the bank feed into signed transactions (positive = money in)."""
import csv
from dataclasses import dataclass
from decimal import Decimal


@dataclass(frozen=True)
class Tx:
    account: str
    date: str
    kind: str
    amount: Decimal  # signed: + money in, - money out


SIGN = {"deposit": 1, "withdrawal": -1, "refund": -1}


def load(path):
    with open(path) as f:
        return [Tx(r["account"], r["date"], r["kind"], SIGN[r["kind"]] * Decimal(r["amount"])) for r in csv.DictReader(f)]
