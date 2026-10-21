import os
import sys
import unittest

sys.path.insert(0, os.getcwd())
from accounts.handles import make_handle  # noqa: E402
from core.text import ascii_fold  # noqa: E402


class Hidden(unittest.TestCase):
    def test_names(self):
        self.assertEqual(make_handle("Zoë O'Brien"), "zoe-obrien")
        self.assertEqual(make_handle("  --Ünïcödé--  "), "unicode")
        self.assertEqual(make_handle("François Lefèvre", taken={"francois-lefevre"}), "francois-lefevre-2")
        self.assertEqual(make_handle("Ada Lovelace"), "ada-lovelace")
        self.assertEqual(ascii_fold("Crème Brûlée"), "Creme Brulee")
