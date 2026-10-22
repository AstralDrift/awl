import os
import sys

from bank import importer, statement

FEED = os.path.join(os.path.dirname(__file__), "..", "data", "feed.csv")

if len(sys.argv) != 3 or sys.argv[1] != "statement":
    print("usage: python3 -m bank statement ACCOUNT")
    sys.exit(2)
sys.stdout.write(statement.render(importer.load(FEED), sys.argv[2]))
