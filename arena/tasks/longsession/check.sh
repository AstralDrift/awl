#!/bin/sh
# All six steps: hidden behavior + migrations, visible tests pass and cover pinning, changelog entry.
python3 "$TASK/hidden_test.py" >.out 2>&1 || { grep -m1 -E '^(FAIL|ERROR|AssertionError)' .out || tail -1 .out; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "visible tests fail: $(grep -m1 -E '^(FAIL|ERROR)' .out)"; exit 1; }
grep -qi 'pin' tests/*.py || { echo "no pin tests"; exit 1; }
sed -n '/^## Unreleased/,/^## 0.3.0/p' CHANGELOG.md | grep -qi pin || { echo "no CHANGELOG entry under Unreleased"; exit 1; }
echo ok
