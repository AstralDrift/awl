"""Generates setup/ for the logapi task (deterministic). Kept so the task can be rebuilt."""
import os
import random
import shutil

random.seed(7)
NAMES = ["billing", "shipping", "search", "auth", "audit", "export", "imports", "cache", "queue", "email",
         "sms", "push", "reports", "tax", "pricing", "coupons", "cart", "orders", "returns", "refunds",
         "stock", "warehouse", "suppliers", "invoices", "payments", "fraud", "users", "sessions", "profiles", "reviews",
         "ratings", "media", "thumbnails", "sitemap", "feeds", "webhooks", "scheduler", "backup", "metrics", "health"]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "setup")
shutil.rmtree(root, ignore_errors=True)
os.makedirs(os.path.join(root, "svc", "mods"))
os.makedirs(os.path.join(root, "tests"))
os.makedirs(os.path.join(root, "docs"))

open(os.path.join(root, "svc", "__init__.py"), "w").write('"""Services that report what they did through svc.logging."""\n')
open(os.path.join(root, "svc", "logging.py"), "w").write('''"""Logging for svc.

Deprecated: log(level, msg) prints "[level] msg" and does not say which module
spoke. Use a named logger instead: at the top of a module,

    from svc.logging import get_logger
    logger = get_logger(__name__)

then logger.info(msg), logger.warn(msg), logger.error(msg), or logger.log(level, msg)
when the level is a variable. Output: "[level] module.name: msg".
"""


def log(level, msg):
    print(f"[{level}] {msg}")


class Logger:
    def __init__(self, name):
        self.name = name

    def log(self, level, msg):
        print(f"[{level}] {self.name}: {msg}")

    def info(self, msg):
        self.log("info", msg)

    def warn(self, msg):
        self.log("warn", msg)

    def error(self, msg):
        self.log("error", msg)


def get_logger(name):
    return Logger(name)
''')
open(os.path.join(root, "svc", "mods", "__init__.py"), "w").write(
    '"""Service modules, run in this order."""\nNAMES = ' + repr(NAMES) + "\n")
open(os.path.join(root, "svc", "__main__.py"), "w").write('''import importlib
import sys

from svc.mods import NAMES

if __name__ == "__main__":
    if sys.argv[1:] != ["run"]:
        sys.exit("usage: python3 -m svc run")
    ctx = {"n": 3}
    for name in NAMES:
        importlib.import_module("svc.mods." + name).run(ctx)
''')
LEVELS = ["info", "warn", "error"]
for i, name in enumerate(NAMES):
    lines = ['"""The %s service."""' % name, "from svc.logging import log", ""]
    body = []
    if i % 5 == 0:  # a helper whose name contains "log("
        lines += ["", "def catalog(items):", "    return sorted(items)", ""]
        body.append('    items = catalog(["b", "a", "c"][: ctx["n"]])')
        body.append('    log("info", f"%s catalog: {items}")' % name)
    k = 2 + i % 3
    for j in range(k):
        lv = LEVELS[(i + j) % 3]
        msg = "%s step %d of %d" % (name, j + 1, k)
        if (i + j) % 7 == 0:  # call split over lines
            body.append('    log(\n        "%s",\n        f"%s (n={ctx[\'n\']})",\n    )' % (lv, msg))
        elif (i + j) % 11 == 0:  # level in a variable
            body.append('    level = "warn" if ctx["n"] > 2 else "info"')
            body.append('    log(level, "%s")' % msg)
        else:
            body.append('    log("%s", "%s")' % (lv, msg))
    lines += ["", "def run(ctx):"] + body + [""]
    open(os.path.join(root, "svc", "mods", name + ".py"), "w").write("\n".join(lines))

open(os.path.join(root, "docs", "LOGGING.md"), "w").write('''# Logging

Services report progress with:

```python
from svc.logging import log
log("info", "billing started")
```
''')
open(os.path.join(root, "README.md"), "w").write("# svc\n\n`python3 -m svc run` runs every service. Tests: `python3 -m unittest discover -s tests`.\n")
open(os.path.join(root, "tests", "test_svc.py"), "w").write('''import contextlib
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
''')
