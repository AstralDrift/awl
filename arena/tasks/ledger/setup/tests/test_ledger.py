import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import ledger


class LastShareTests(unittest.TestCase):
    def test_even_split(self):
        self.assertEqual(ledger.last_share(100, 4), 25)

    def test_remainder_goes_to_the_last_person(self):
        # 33 + 33 + 34
        self.assertEqual(ledger.last_share(100, 3), 34)

    def test_one_person_pays_the_total(self):
        self.assertEqual(ledger.last_share(7, 1), 7)


if __name__ == "__main__":
    unittest.main()
