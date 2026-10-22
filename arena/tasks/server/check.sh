#!/bin/sh
# /stats correct (fresh server, two calls so the cached path runs), nothing left on 8099.
leftover=$(ss -ltnpH 'sport = :8099' 2>/dev/null)
if [ -n "$leftover" ]; then
  echo "server left running on 8099"
  for p in $(echo "$leftover" | grep -o 'pid=[0-9]*' | cut -d= -f2); do kill "$p" 2>/dev/null; done
  exit 1
fi
python3 - <<'PY'
import json, socket, subprocess, sys, time, urllib.request
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
p = subprocess.Popen([sys.executable, "-m", "svc", "--port", str(port)])
try:
    for _ in range(50):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1); break
        except OSError:
            time.sleep(0.1)
    for _ in range(2):
        r = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/stats", timeout=2))
        assert r == {"count": 3, "units": 6, "total": 60}, r
    import svc.cache as c
    assert c.cached("k", lambda: 41 + 1) == 42, "cache.cached must return the computed value"
    assert c.cached("k", lambda: 0) == 42, "second call must hit the cache"
    print("ok")
except AssertionError as e:
    print("hidden:", e); sys.exit(1)
except Exception as e:
    print("hidden:", type(e).__name__, e); sys.exit(1)
finally:
    p.kill()
PY
