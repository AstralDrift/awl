import contextlib
import io
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from svc.mods import NAMES  # noqa: E402
import importlib  # noqa: E402


class SvcTest(unittest.TestCase):
    def test_every_service_logs(self):
        for name in NAMES:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                importlib.import_module("svc.mods." + name).run({"n": 3})
            self.assertIn(name, buf.getvalue())


if __name__ == "__main__":
    unittest.main()
