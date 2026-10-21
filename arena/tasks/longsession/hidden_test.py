import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.getcwd())
from notes.cli import main  # noqa: E402
from notes import migrations  # noqa: E402


class Hidden(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "n.json")

    def tearDown(self):
        self.dir.cleanup()

    def cli(self, *argv):
        out = io.StringIO()
        return main(["--db", self.db, *argv], out), out.getvalue()

    def test_pin_flow(self):
        for t in ("a", "b", "c", "d"):
            self.cli("add", t)
        self.cli("add", "e", "--tag", "w")
        self.assertEqual(self.cli("pin", "3"), (0, "pinned 3\n"))
        self.assertEqual(self.cli("pin", "5"), (0, "pinned 5\n"))
        self.assertEqual(self.cli("pin", "9"), (1, "no note 9\n"))
        self.assertEqual(self.cli("list")[1], "  3* c\n  5* e  [w]\n  1  a\n  2  b\n  4  d\n")
        self.assertEqual(self.cli("list", "--tag", "w")[1], "  5* e  [w]\n")
        self.assertEqual(self.cli("unpin", "3"), (0, "unpinned 3\n"))
        self.assertEqual(self.cli("unpin", "9"), (1, "no note 9\n"))
        self.assertEqual(self.cli("list")[1], "  5* e  [w]\n  1  a\n  2  b\n  3  c\n  4  d\n")
        data = json.load(open(self.db))
        self.assertEqual(data["version"], 3)
        self.assertEqual([n["pinned"] for n in data["notes"]], [False, False, False, False, True])

    def test_migrations(self):
        self.assertEqual(migrations.CURRENT, 3)
        for raw in ([{"id": 1, "title": "v0"}],
                    {"version": 1, "notes": [{"id": 1, "title": "v1"}]},
                    {"version": 2, "notes": [{"id": 1, "title": "v2", "tags": ["x"]}]}):
            with open(self.db, "w") as f:
                json.dump(raw, f)
            self.assertEqual(self.cli("list")[1].splitlines()[0][:4], "  1 ")
            self.cli("pin", "1")
            data = json.load(open(self.db))
            self.assertEqual(data["version"], 3)
            self.assertTrue(data["notes"][0]["pinned"])
            self.assertIn("tags", data["notes"][0])

    def test_export_unchanged(self):
        self.cli("add", "t", "b", "--tag", "x")
        self.cli("pin", "1")
        self.assertEqual(self.cli("export")[1], "## t _(x)_\n\nb\n")
