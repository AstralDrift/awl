#!/bin/sh
python3 -c '
import json
d = json.load(open("settings.json"))
assert d == {"name": "awl", "retries": 3, "hosts": ["a.local", "b.local"], "debug": False, "timeout_ms": 2500}, d
'
