#!/bin/sh
# Hidden behavior tests under ASan/UBSan with leak checking, an O(1) timing test, and make test.
cmp -s lru.h "$SETUP/lru.h" || { echo "lru.h changed"; exit 1; }
cc -O1 -g -std=c11 -fsanitize=address,undefined -fno-sanitize-recover=all -I. -o .hidden "$TASK/hidden_test.c" lru.c 2>.out || { grep -m1 error .out; exit 1; }
ASAN_OPTIONS=detect_leaks=1 ./.hidden >.out 2>&1 || { grep -m1 -E 'hidden:|ERROR|SUMMARY' .out || tail -1 .out; exit 1; }
cc -O2 -std=c11 -I. -o .perf "$TASK/hidden_test.c" lru.c || exit 1
timeout 5 ./.perf perf || { echo "hidden: perf test failed or over 5s (not O(1)?)"; exit 1; }
make test >/dev/null 2>&1 || { echo "make test fails"; exit 1; }
echo ok
