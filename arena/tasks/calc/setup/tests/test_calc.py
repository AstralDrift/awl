import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from calc import run_line  # noqa: E402


class CalcTest(unittest.TestCase):
    def test_add(self):
        self.assertEqual(run_line("1 + 2", {}), "3")

    def test_let(self):
        env = {}
        self.assertEqual(run_line("let x = 4", env), "x = 4")
        self.assertEqual(run_line("x * x", env), "16")

    def test_blank(self):
        self.assertIsNone(run_line("   ", {}))
        self.assertIsNone(run_line("# note", {}))


if __name__ == "__main__":
    unittest.main()
