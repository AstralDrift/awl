#!/bin/sh
# zig build test passes on zig 0.16 and the hidden API tests pass too.
zig version | grep -q '^0\.16' || { echo "need zig 0.16 on PATH"; exit 1; }
zig build test >.out 2>&1 || { grep -m1 error .out || tail -1 .out; exit 1; }
cp "$TASK/hidden_test.zig" src/hidden_test.zig
zig test src/hidden_test.zig >.out 2>&1 || { grep -m1 -i 'error\|fail' .out || tail -1 .out; exit 1; }
echo ok
