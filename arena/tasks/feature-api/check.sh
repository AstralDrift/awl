#!/bin/sh
# Hidden DELETE tests pass, visible suite passes and covers DELETE, README documents it.
node --test "$TASK/hidden_test.js" >.out 2>&1 || { grep -m1 -E 'AssertionError|Error|expected' .out || tail -1 .out; exit 1; }
node --test test/ >.out 2>&1 || { echo "visible tests fail"; exit 1; }
grep -q DELETE test/*.js || { echo "no DELETE test added"; exit 1; }
grep -q '| DELETE' README.md || { echo "README not updated"; exit 1; }
echo ok
