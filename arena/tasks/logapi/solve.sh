#!/bin/sh
python3 - <<'P'
import glob, re
for p in sorted(glob.glob("svc/mods/*.py")):
    if p.endswith("__init__.py"):
        continue
    s = open(p).read()
    s = s.replace("from svc.logging import log\n", "from svc.logging import get_logger\n\nlogger = get_logger(__name__)\n")
    s = re.sub(r'\blog\(\s*"(info|warn|error)",\s*', r"logger.\1(", s)
    s = re.sub(r"\blog\(\s*(\w+),\s*", r"logger.log(\1, ", s)
    open(p, "w").write(s)
p = "svc/logging.py"
s = open(p).read()
s = s.replace('''

def log(level, msg):
    print(f"[{level}] {msg}")
''', "")
s = s.replace('''Deprecated: log(level, msg) prints "[level] msg" and does not say which module
spoke. Use a named logger instead: at the top of a module,''', "At the top of a module:")
open(p, "w").write(s)
open("docs/LOGGING.md", "w").write("""# Logging

Each module gets a named logger:

```python
from svc.logging import get_logger
logger = get_logger(__name__)
logger.info("billing started")   # [info] svc.mods.billing: billing started
```

`logger.warn`, `logger.error`, and `logger.log(level, msg)` when the level is a variable.
""")
P
