#!/bin/sh
# Budget gate. Usage: tests/check.sh [path/to/awl]
set -eu
B=${1:-zig-out/bin/awl}
fail() { echo "CHECK FAIL: $*"; exit 1; }
ok() { echo "ok  $*"; }

size=$(stat -c %s "$B")
# A goal, not a cap: raise it only for features people use. (The TUI basics took it to
# 224 KB; dropping std.json's float fallback, see src/jint.zig, brought it back to 199 KB.
# The QOL round the user asked for (welcome, status line, pickers, full screen) has the
# AGENTS.md soft goal of 256 KB.)
[ "$size" -le 262144 ] || fail "size $size > 256 KB"
ok "size $size B"

# `return f() == {}` reads as "return after f" but returns true; in tui.command true
# means quit (it made /resume quit awl). Write the call, then `return false`.
! grep -n '== {}' "$(dirname "$0")"/../src/*.zig || fail "'== {}' in src (see the comment above)"
ok "no '== {}'"

file "$B" | grep -q 'statically linked' || fail "not static"
ok "static"

idle=$("$B" --idle-rss)
[ "$idle" -le 1536 ] || fail "idle RSS ${idle} KB > 1.5 MB"
ok "idle RSS ${idle} KB"

if command -v hyperfine >/dev/null; then
  j=$(mktemp)
  hyperfine -N -w 20 -r 200 --export-json "$j" "$B --version" >/dev/null 2>&1
  ms=$(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["results"][0]["summary"]["time_wall_clock"]["mean"]*1000,3))' "$j")
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
