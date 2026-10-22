"""Feeds hidden_input.txt to `python3 calc.py` and compares every output line."""
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
inp = open(os.path.join(here, "hidden_input.txt")).read()
want = open(os.path.join(here, "hidden_expected.txt")).read().splitlines()
r = subprocess.run([sys.executable, "calc.py"], input=inp, capture_output=True, text=True, timeout=30)
got = r.stdout.splitlines()
stmts = [l for l in inp.splitlines() if l.strip() and not l.lstrip().startswith("#")]
for i, (s, w) in enumerate(zip(stmts, want)):
    g = got[i] if i < len(got) else "<no output>"
    if g != w:
        print(f"AssertionError: {s!r}: want {w!r}, got {g!r}")
        sys.exit(1)
if len(got) != len(want):
    print(f"AssertionError: {len(got)} output lines, want {len(want)}; stderr: {r.stderr[-200:]}")
    sys.exit(1)
print("hidden ok")
