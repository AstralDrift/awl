import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.getcwd())
from todo.cli import main  # noqa: E402


class HiddenJson(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "t.json")

    def tearDown(self):
        self.dir.cleanup()

    def cli(self, *argv):
        out = io.StringIO()
        rc = main(["--db", self.db, *argv], out)
        return rc, out.getvalue()

    def test_json_types_and_filters(self):
        self.cli("add", 'Say "hi"', "--due", "2026-11-01")
        self.cli("add", "Ünïcode ✓")
        self.cli("done", "2")
        rc, out = self.cli("list", "--format", "json")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out), [
            {"id": 1, "title": 'Say "hi"', "done": False, "due": "2026-11-01"},
            {"id": 2, "title": "Ünïcode ✓", "done": True, "due": None},
        ])
        self.assertEqual([t["id"] for t in json.loads(self.cli("list", "--done", "--format", "json")[1])], [2])
        self.assertEqual([t["id"] for t in json.loads(self.cli("list", "--pending", "--format", "json")[1])], [1])

    def test_empty(self):
        self.assertEqual(json.loads(self.cli("list", "--format", "json")[1]), [])

    def test_help_and_text_unchanged(self):
        h = subprocess.run([sys.executable, "-m", "todo", "list", "--help"], capture_output=True, text=True).stdout
        self.assertIn("json", h)
        self.cli("add", "a")
        self.assertEqual(self.cli("list")[1], "[ ] #1 a\n")
        self.assertEqual(self.cli("list", "--format", "csv")[1], "id,title,done,due\n1,a,no,\n")


if __name__ == "__main__":
    unittest.main()
