import io
import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
from notes.cli import main  # noqa: E402


class NotesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.dir.name, "n.json")

    def tearDown(self):
        self.dir.cleanup()

    def cli(self, *argv):
        out = io.StringIO()
        return main(["--db", self.db, *argv], out), out.getvalue()

    def test_add_list_rm(self):
        self.cli("add", "first", "body")
        self.cli("add", "second", "--tag", "work")
        self.assertEqual(self.cli("list")[1], "  1  first\n  2  second  [work]\n")
        self.assertEqual(self.cli("list", "--tag", "work")[1], "  2  second  [work]\n")
        self.assertEqual(self.cli("rm", "1"), (0, "removed 1\n"))
        self.assertEqual(self.cli("rm", "1"), (1, "no note 1\n"))

    def test_migrates_v1(self):
        shutil.copy(os.path.join(HERE, "fixtures", "v1.json"), self.db)
        self.assertEqual(self.cli("list")[1], "  1  old\n")
        self.cli("add", "new")
        data = json.load(open(self.db))
        self.assertEqual(data["version"], 2)
        self.assertEqual(data["notes"][0]["tags"], [])

    def test_export(self):
        self.cli("add", "t", "b", "--tag", "x")
        self.assertEqual(self.cli("export")[1], "## t _(x)_\n\nb\n")
