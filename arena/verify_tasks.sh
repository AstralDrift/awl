#!/bin/sh
# Each task's check must fail on the untouched setup and pass after its solve.sh.
cd "$(dirname "$0")/tasks"
rc=0
for t in */; do
  t=${t%/}
  w=$(mktemp -d)
  cp -r "$t/setup/." "$w/"
  if (cd "$w" && SETUP="$OLDPWD/$t/setup" sh "$OLDPWD/$t/check.sh" >/dev/null 2>&1); then echo "FAIL $t: passes unsolved"; rc=1; fi
  (cd "$w" && sh "$OLDPWD/$t/solve.sh" >/dev/null 2>&1)
  if (cd "$w" && SETUP="$OLDPWD/$t/setup" sh "$OLDPWD/$t/check.sh" >/dev/null 2>&1); then echo "ok   $t"; else echo "FAIL $t: solve does not pass"; rc=1; fi
  rm -rf "$w"
done
exit $rc
