import json
import sys

from billing.invoice import from_order
from billing.render import render


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if len(argv) != 2 or argv[0] != "invoice":
        print("usage: python3 -m billing.cli invoice ORDER.json", file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        sys.stdout.write(render(from_order(json.load(f))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
