#!/bin/sh
# The suite passes under 10 hash seeds in two far-apart timezones, with no test removed.
n=$(grep -c '    def test_' tests/test_report.py)
[ "$n" -ge 5 ] || { echo "tests removed ($n)"; exit 1; }
grep -q 'skip' tests/test_report.py && { echo "tests skipped"; exit 1; }
for tz in Pacific/Kiritimati Etc/GMT+12; do
  for seed in 0 1 2 3 4 5 6 7 8 9; do
    out=$(TZ=$tz PYTHONHASHSEED=$seed python3 -m unittest discover -s tests 2>&1) || { echo "fails tz=$tz seed=$seed: $(echo "$out" | grep -m1 -E '^(FAIL|ERROR):')"; exit 1; }
    echo "$out" | grep -q "^Ran [5-9]" || { echo "too few tests ran"; exit 1; }
  done
done
echo ok
