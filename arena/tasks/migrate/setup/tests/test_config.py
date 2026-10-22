import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app.config import load_config  # noqa: E402


class ConfigTest(unittest.TestCase):
    def test_load(self):
        c = load_config()
        self.assertEqual(c.timeout, 12)
        self.assertEqual(c.retries, 3)
        self.assertEqual(c.feature_flags, frozenset({"fast_path", "new_ui"}))


if __name__ == "__main__":
    unittest.main()
