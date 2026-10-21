import datetime
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from report import data, render  # noqa: E402


class TestRender(unittest.TestCase):
    def test_item_line(self):
        self.assertEqual(render.item_line({"id": 7, "title": "x"}), "#7   x")

    def test_tags_line(self):
        self.assertEqual(render.tags_line(["gamma", "alpha", "beta", "alpha"]), "alpha, beta, gamma")

    def test_header_has_today(self):
        today = datetime.date.today().isoformat()
        self.assertEqual(render.header("Daily"), f"Daily — {today}")

    def test_render_ends_with_tags(self):
        out = render.render("Daily", data.ITEMS)
        self.assertTrue(out.endswith("tags: auth, bug, docs, ops, release\n"), out)

    def test_all_tags_keeps_duplicates(self):
        self.assertEqual(len(data.all_tags(data.ITEMS)), 6)


if __name__ == "__main__":
    unittest.main()
