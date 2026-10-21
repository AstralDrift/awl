#!/bin/sh
# Hidden JSON tests pass, the visible suite still passes and gained a json test, README mentions json.
python3 "$TASK/hidden_test.py" >.out 2>&1 || { grep -m1 -E '^(FAIL|ERROR|AssertionError)' .out || tail -1 .out; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "visible tests fail"; exit 1; }
grep -qi json tests/*.py || { echo "no json test added"; exit 1; }
grep -qi json README.md || { echo "README not updated"; exit 1; }
echo ok
