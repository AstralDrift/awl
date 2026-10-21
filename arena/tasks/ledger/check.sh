#!/bin/sh
# tests pass, only src/ledger.py changed, RESULT.txt says PASS + a reason
python3 tests/test_ledger.py >/dev/null 2>&1 || exit 1
for f in src/tax.py README.md tests/test_ledger.py; do cmp -s "$f" "$SETUP/$f" || exit 1; done
[ "$(head -1 RESULT.txt 2>/dev/null)" = "PASS" ] && [ -n "$(sed -n 2p RESULT.txt)" ]
