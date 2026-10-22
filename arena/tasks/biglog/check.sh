#!/bin/sh
cmp -s tests/run.py "$SETUP/tests/run.py" || { echo "tests/run.py changed"; exit 1; }
cmp -s data/records.tsv "$SETUP/data/records.tsv" || { echo "data changed"; exit 1; }
python3 tests/run.py >.out 2>&1 || { tail -1 .out; exit 1; }
python3 "$TASK/hidden_test.py" 2>&1 | tail -1 | grep -q "hidden ok" || { python3 "$TASK/hidden_test.py" 2>&1 | tail -1; exit 1; }
echo ok
