#!/bin/sh
# Budget gate. Usage: tests/check.sh [path/to/awl]
set -eu
B=${1:-zig-out/bin/awl}
fail() { echo "CHECK FAIL: $*"; exit 1; }
ok() { echo "ok  $*"; }

size=$(stat -c %s "$B")
echo "    size $size B (reported, not checked)"

# Source rules ('== {}', test imports) moved to tests/lint.sh (zig build lint).

file "$B" | grep -q 'statically linked' || fail "not static"
ok "static"

idle=$("$B" --idle-rss)
echo "    idle RSS ${idle} KB (reported, not checked)"

if command -v hyperfine >/dev/null; then
  j=$(mktemp)
  hyperfine -N -w 20 -r 200 --export-json "$j" "$B --version" >/dev/null 2>&1
  ms=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"][0]; print(round(r["summary"]["time_wall_clock"]["mean"]*1000 if "summary" in r else r["mean"]*1000,3))' "$j")
  rm -f "$j"
  python3 -c "import sys; sys.exit(0 if $ms <= 3 else 1)" || fail "startup ${ms} ms > 3 ms"
  ok "startup ${ms} ms"
else
  echo "skip startup (no hyperfine)"
fi

if [ -x tests/peak.sh ]; then
  peak=$(tests/peak.sh "$B")
  [ "$peak" -le 8192 ] || fail "peak RSS ${peak} KB > 8 MB"
  ok "peak RSS ${peak} KB (50-turn scripted session)"
fi
echo "CHECK PASS"
