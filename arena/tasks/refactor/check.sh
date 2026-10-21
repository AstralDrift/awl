#!/bin/sh
# Every module prints exactly what it did before, the old export is gone, unrelated local formatPrice helpers are untouched.
for f in src/admin/csv.js src/legacy/pos.js; do cmp -s "$f" "$SETUP/$f" || { echo "changed unrelated $f"; exit 1; }; done
node "$TASK/golden.js" >.out 2>&1 || { grep -m1 Error .out; exit 1; }
diff -q .out "$TASK/golden.txt" >/dev/null || { diff .out "$TASK/golden.txt" | sed -n 2p; exit 1; }
node -e "const f=require('./lib/format'); if ('formatPrice' in f) { console.log('formatPrice still exported'); process.exit(1) }" || exit 1
left=$(grep -rln formatPrice src lib test | grep -v -e src/admin/csv.js -e src/legacy/pos.js)
[ -z "$left" ] || { echo "formatPrice still referenced in $left"; exit 1; }
node --test test/ >.out 2>&1 || { echo "tests fail"; exit 1; }
echo ok
