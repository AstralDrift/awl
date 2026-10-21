#!/bin/sh
python3 - <<'PY'
s = open("words.py").read()
s = s.replace("for w in sorted(set(words)):", 'for w in sorted(set(words), reverse="--reverse" in argv):')
open("words.py", "w").write(s)
PY
