#!/bin/sh
python3 "$TASK/hidden_test.py" >.out 2>&1; tail -1 .out | grep -q "hidden ok" || { grep -m1 "AssertionError" .out || tail -1 .out; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "visible tests fail: $(grep -m1 -E '^(FAIL|ERROR)' .out)"; exit 1; }
n=$(grep -ho 'def test' tests/*.py | wc -l)
[ "$n" -ge 5 ] || { echo "only $n tests; add tests for what you built"; exit 1; }
echo ok
