import importlib
import sys

from app.services import NAMES


def main(argv):
    if argv[1:] != ["report"]:
        print("usage: python3 -m app report")
        return 2
    for n in NAMES:
        print(importlib.import_module(f"app.services.{n}").describe())
    return 0


sys.exit(main(sys.argv))
