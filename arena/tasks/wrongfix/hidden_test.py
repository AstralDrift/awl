import os
import subprocess
import sys
from decimal import Decimal

sys.path.insert(0, os.getcwd())
from bank import importer, ledger  # noqa: E402

txs = importer.load("data/feed.csv")
assert ledger.balance(txs, "A-17") == Decimal("45.50"), ledger.balance(txs, "A-17")
assert ledger.balance(txs, "C-31") == Decimal("90.00"), ledger.balance(txs, "C-31")
assert ledger.balance(txs, "B-02") == Decimal("-50.00"), f"B-02 really overdrew: {ledger.balance(txs, 'B-02')}"
refunds = [t for t in txs if t.kind == "refund"]
assert all(t.amount > 0 for t in refunds), "a refund is money in: the signed amount must be positive"
out = subprocess.run([sys.executable, "-m", "bank", "statement", "B-02"], capture_output=True, text=True).stdout
assert "closing balance: -50.00" in out, out
out = subprocess.run([sys.executable, "-m", "bank", "statement", "A-17"], capture_output=True, text=True).stdout
assert "closing balance: 45.50" in out and "refund" in out and "40.00" in out, out
print("hidden ok")
