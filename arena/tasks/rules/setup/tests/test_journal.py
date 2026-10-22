import datetime
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from journal import clock  # noqa: E402
from journal.commands import COMMANDS  # noqa: E402
from journal.store import Store  # noqa: E402


class JournalTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.store = Store(self.d.name)
        self.real_now = clock.now
        clock.now = lambda: datetime.datetime(2026, 10, 1, 9, 0, 0)

    def tearDown(self):
        clock.now = self.real_now
        self.d.cleanup()

    def test_add_list(self):
        self.assertEqual(COMMANDS["add"](self.store, ["hello"]), "added entry 1")
        self.assertEqual(COMMANDS["list"](self.store, []), "2026-10-01T09:00:00  hello")


if __name__ == "__main__":
    unittest.main()
