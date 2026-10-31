#!/bin/sh
python3 -m app report >.out 2>&1 || { tail -1 .out; exit 1; }
cmp -s .out "$TASK/../migrate/golden.txt" || { diff .out "$TASK/../migrate/golden.txt" | head -3; exit 1; }
python3 - <<'PY' || exit 1
import ast, glob, sys
for p in glob.glob("app/**/*.py", recursive=True):
    for n in ast.walk(ast.parse(open(p).read())):
        hit = (isinstance(n, ast.Name) and n.id in ("settings", "_load_settings")) or \
              (isinstance(n, ast.alias) and n.name in ("settings", "_load_settings")) or \
              (isinstance(n, ast.FunctionDef) and n.name == "_load_settings")
        if hit:
            print(f"old settings still used: {p}:{n.lineno}"); sys.exit(1)
PY
python3 -c "import app.config as c; assert not hasattr(c, 'settings'), 'settings dict still defined'" || exit 1
grep -q 'load_config' docs/CONFIG.md && grep -q 'Config' docs/CONFIG.md || { echo "docs do not describe load_config()/Config"; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "tests fail"; exit 1; }
sh "$TASK/probe.sh" || exit 1
