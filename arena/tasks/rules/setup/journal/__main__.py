import os
import sys

from journal.commands import COMMANDS
from journal.store import Store

root = os.environ.get("JOURNAL_DIR", os.path.expanduser("~/.journal"))
if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
    print("usage: python3 -m journal {" + ",".join(COMMANDS) + "} ...")
    sys.exit(2)
print(COMMANDS[sys.argv[1]](Store(root), sys.argv[2:]))
