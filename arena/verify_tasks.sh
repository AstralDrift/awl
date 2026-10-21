#!/bin/sh
# Each task's check must fail on the untouched setup and pass after its solve.sh.
# Usage: arena/verify_tasks.sh [task...]
cd "$(dirname "$0")/tasks"
T=$(pwd)
rc=0
# Sandboxes live outside the repo (like arena runs); zig comes from the repo's mise pin.
Z=$(cd "$T/../.." && mise where zig 2>/dev/null) && export PATH="$Z:$PATH"
mkdir -p /tmp/awl-arena
[ $# -gt 0 ] || set -- */
for t in "$@"; do
  t=${t%/}
  w=$(mktemp -d -p /tmp/awl-arena verify.XXXX)
  cp -r "$t/setup/." "$w/"
  export SETUP="$T/$t/setup" TASK="$T/$t"
  [ -f "$t/setup.sh" ] && (cd "$w" && sh "$TASK/setup.sh" >/dev/null 2>&1)
  if (cd "$w" && sh "$TASK/check.sh" >/dev/null 2>&1); then echo "FAIL $t: passes unsolved"; rc=1; fi
  (cd "$w" && sh "$TASK/solve.sh" >/dev/null 2>&1)
  if out=$(cd "$w" && sh "$TASK/check.sh" 2>&1); then echo "ok   $t"; else echo "FAIL $t: solve does not pass: $(echo "$out" | tail -1)"; rc=1; fi
  rm -rf "$w"
done
exit $rc
