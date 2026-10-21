#!/bin/sh
# EUR (and every other currency) totals are right, visible tests still pass, no hardcoded EUR special case.
python3 "$TASK/hidden_test.py" >.out 2>&1 || { grep -m1 -E '^(FAIL|ERROR|AssertionError)' .out || tail -1 .out; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "visible tests fail"; exit 1; }
grep -n '"EUR"' billing/*.py | grep -v catalog.py && { echo "special-cased EUR in code"; exit 1; }
echo ok
