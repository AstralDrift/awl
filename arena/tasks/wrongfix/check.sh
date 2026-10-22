#!/bin/sh
cmp -s data/feed.csv "$SETUP/data/feed.csv" || { echo "feed changed"; exit 1; }
python3 "$TASK/hidden_test.py" >.out 2>&1; tail -1 .out | grep -q "hidden ok" || { grep -m1 -E "AssertionError|Error" .out || tail -1 .out; exit 1; }
python3 -m unittest discover -s tests >.out 2>&1 || { echo "visible tests fail"; exit 1; }
echo ok
