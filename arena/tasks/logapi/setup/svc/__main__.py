import importlib
import sys

from svc.mods import NAMES

if __name__ == "__main__":
    if sys.argv[1:] != ["run"]:
        sys.exit("usage: python3 -m svc run")
    ctx = {"n": 3}
    for name in NAMES:
        importlib.import_module("svc.mods." + name).run(ctx)
