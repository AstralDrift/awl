#!/bin/sh
python3 -m svc run >.out 2>&1 || { tail -1 .out; exit 1; }
cmp -s .out "$TASK/golden.txt" || { diff .out "$TASK/golden.txt" | head -3; exit 1; }
python3 - <<'PY' || exit 1
import ast, glob, sys
for p in glob.glob("svc/**/*.py", recursive=True):
    tree = ast.parse(open(p).read())
    for n in ast.walk(tree):
        old = (isinstance(n, ast.ImportFrom) and n.module == "svc.logging" and any(a.name == "log" for a in n.names)) or \
              (isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "log")
        if old:
            print(f"old log() still used: {p}:{n.lineno}"); sys.exit(1)
    if p.endswith("logging.py") and any(isinstance(n, ast.FunctionDef) and n.name == "log" for n in tree.body):
        print("svc/logging.py still defines log()"); sys.exit(1)
PY
grep -q 'get_logger' docs/LOGGING.md || { echo "docs/LOGGING.md does not describe get_logger"; exit 1; }
grep -q 'import log$' docs/LOGGING.md && { echo "docs/LOGGING.md still shows the old import"; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "tests fail"; exit 1; }
echo ok
