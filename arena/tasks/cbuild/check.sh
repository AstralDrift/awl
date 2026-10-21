#!/bin/sh
# make test passes from clean, the API files are untouched, hidden edge cases hold.
for f in src/stats.h src/main.c src/fmt.c src/fmt.h tests/test_stats.c; do
  cmp -s "$f" "$SETUP/$f" || { echo "changed $f"; exit 1; }
done
make clean >/dev/null 2>&1
make test >/tmp/cbuild.$$ 2>&1 || { tail -3 /tmp/cbuild.$$; rm -f /tmp/cbuild.$$; exit 1; }
rm -f /tmp/cbuild.$$
cc -O2 -std=c11 -Isrc -o .hidden "$TASK/hidden_test.c" src/stats.o -lm || { echo "hidden build failed"; exit 1; }
./.hidden
