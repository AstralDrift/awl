#!/bin/sh
python3 -m app report >.out 2>&1 || { tail -1 .out; exit 1; }
cmp -s .out "$TASK/golden.txt" || { diff .out "$TASK/golden.txt" | head -3; exit 1; }
grep -rn 'settings\[\|settings\.get\|import settings\|_load_settings' app >.g && { echo "old settings still used: $(head -1 .g)"; exit 1; }
python3 -c "import app.config as c; assert not hasattr(c, 'settings'), 'settings dict still defined'" || exit 1
grep -q 'load_config' docs/CONFIG.md || { echo "docs not updated"; exit 1; }
grep -q 'settings\[' docs/CONFIG.md && { echo "docs still describe the settings dict"; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "tests fail"; exit 1; }
echo ok
