"""Data-driven check of parse_amount over data/records.tsv. Prints one line per case."""
import os
import sys
from decimal import Decimal

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from money.amounts import parse_amount  # noqa: E402

failed = 0
rows = open(os.path.join(os.path.dirname(__file__), "..", "data", "records.tsv")).read().splitlines()
for n, row in enumerate(rows, 1):
    text, want, code = row.split("\t")
    try:
        got = parse_amount(text)
        ok = got == (Decimal(want), code)
    except Exception as e:  # noqa: BLE001
        got, ok = f"{type(e).__name__}: {e}", False
    if ok:
        print(f"case {n:04d} ok    parse_amount({text!r})")
    else:
        failed += 1
        print(f"case {n:04d} FAIL  parse_amount({text!r}) -> {got!r}, expected ({want}, {code})")
print(f"{len(rows) - failed} passed, {failed} failed" + (" (details above)" if failed else ""))
sys.exit(1 if failed else 0)
