import os
import sys
import unittest
from decimal import Decimal

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from bank.importer import Tx  # noqa: E402
from bank.ledger import balance  # noqa: E402


class LedgerTest(unittest.TestCase):
    def test_deposits_and_withdrawals(self):
        txs = [Tx("X", "d", "deposit", Decimal("100")), Tx("X", "d", "withdrawal", Decimal("-30"))]
        self.assertEqual(balance(txs, "X"), Decimal("70"))


if __name__ == "__main__":
    unittest.main()
