import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from todo.cli import main  # noqa: E402


class CliTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "t.json")

    def tearDown(self):
        self.dir.cleanup()

    def run_cli(self, *argv):
        out = io.StringIO()
        rc = main(["--db", self.db, *argv], out)
        return rc, out.getvalue()

    def test_add_and_list(self):
        self.run_cli("add", "Buy milk", "--due", "2026-11-01")
        self.run_cli("add", "Call mom")
        rc, out = self.run_cli("list")
        self.assertEqual(rc, 0)
        self.assertEqual(out, "[ ] #1 Buy milk  (due 2026-11-01)\n[ ] #2 Call mom\n")

    def test_done_filters(self):
        self.run_cli("add", "a")
        self.run_cli("add", "b")
        self.run_cli("done", "1")
        self.assertEqual(self.run_cli("list", "--done")[1], "[x] #1 a\n")
        self.assertEqual(self.run_cli("list", "--pending")[1], "[ ] #2 b\n")

    def test_csv(self):
        self.run_cli("add", "x, y")
        self.assertEqual(self.run_cli("list", "--format", "csv")[1], 'id,title,done,due\n1,"x, y",no,\n')

    def test_rm_missing(self):
        self.assertEqual(self.run_cli("rm", "9"), (1, "no task #9\n"))


if __name__ == "__main__":
    unittest.main()
