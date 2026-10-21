#!/bin/sh
# Hidden name cases pass, the visible test file is unchanged, generated code is untouched.
cmp -s tests/test_handles.py "$SETUP/tests/test_handles.py" || { echo "test file changed"; exit 1; }
python3 "$TASK/hidden_test.py" >.out 2>&1 || { grep -m1 -E '^(FAIL|ERROR|AssertionError)' .out || tail -1 .out; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "visible tests fail"; exit 1; }
ref=$(mktemp -d)
(cd "$ref" && sh "$TASK/setup.sh")
for d in services vendor legacy; do
  diff -rq -x __pycache__ "$ref/$d" "$d" >/dev/null || { echo "changed generated $d/"; rm -rf "$ref"; exit 1; }
done
rm -rf "$ref"
echo ok
