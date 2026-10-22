#!/bin/sh
python3 - <<'P'
p = "svc/cache.py"; s = open(p).read()
s = s.replace("        put(key, compute)\n    return get(key)", "        value = compute()\n        put(key, value)\n    return value")
open(p, "w").write(s)
P
