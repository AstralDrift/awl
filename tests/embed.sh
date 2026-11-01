#!/bin/bash
# What programs that run awl rely on (docs/embedding.md), held in place against
# tests/fake_sse.py. Usage: tests/embed.sh [path/to/awl]
set -u
AWL=$(realpath "${1:-zig-out/bin/awl}")
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
unset AWL_URL AWL_MODEL AWL_KEY AWL_SYSTEM AWL_MAX_STEPS AWL_RSS AWL_AGENTS AWL_MODE AWL_SUMMARY AWL_NETWORK
pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# --version: one line on stdout, exit 0, the build.zig.zon version and a 7-digit commit
# (or "unknown" for a build without git).
ver=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$HERE/../build.zig.zon")
out=$("$AWL" --version 2>"$W/err")
rc=$?
[[ $rc -eq 0 && $out =~ ^awl\ ${ver//./\\.}\ \(([0-9a-f]{7}|unknown)\)$ && $(printf '%s\n' "$out" | wc -l) -eq 1 && ! -s $W/err ]] &&
  ok "--version: '$out'" || bad "--version" "rc=$rc out='$out' want 'awl $ver (<commit>)' err=$(cat "$W/err")"

echo "embed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
