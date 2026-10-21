import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from accounts.handles import make_handle  # noqa: E402


class Handles(unittest.TestCase):
    def test_plain(self):
        self.assertEqual(make_handle("Ada Lovelace"), "ada-lovelace")

    def test_accents(self):
        self.assertEqual(make_handle("José Núñez"), "jose-nunez")

    def test_taken_and_reserved(self):
        self.assertEqual(make_handle("Admin"), "admin-user")
        self.assertEqual(make_handle("ada", taken={"ada", "ada-2"}), "ada-3")
