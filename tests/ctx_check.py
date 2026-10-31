#!/usr/bin/env python3
"""Assert the last request elided the oldest tool outputs and kept the newest.
  ctx_check.py LOG fresh    the marker points into the session view, and reading it there gives the
                            output back exactly (budget lines included)
  ctx_check.py LOG compact  the default: the old marker, no budget line, no view written"""
import json
import re
import sys

reqs = [json.loads(l) for l in open(sys.argv[1])]
m = reqs[-1]["messages"]
tools = [x["content"] for x in m if x["role"] == "tool"]
assert any(c.startswith("[old tool output elided") for c in tools), "nothing elided"
assert not tools[-2].startswith("[old"), "newest output elided"
assert tools[0].startswith("[old"), "oldest output kept"
assert all(x.get("tool_call_id") for x in m if x["role"] == "tool")
mk = tools[0]
if sys.argv[2] == "compact":
    assert mk == "[old tool output elided to save context; rerun the tool if you need it]", mk
    assert "[time " not in json.dumps(m), "budget line in compact mode"
    import glob, os
    views = glob.glob(os.path.join(os.environ["XDG_STATE_HOME"], "awl", "sessions", "view-*.txt"))
    assert not views, views
    sys.exit(0)
assert re.search(r"it is in /\S*/view-\d+\.txt lines \d+-\d+: read it there \(offset=\d+, limit=\d+\) instead of rerunning", mk), mk
assert "rerun the tool if you need it" not in json.dumps(m), "old marker"
# the original output, as the first request that carried it had it
orig = next(x["content"] for r in reqs for x in r["messages"] if x["role"] == "tool")
back = tools[-1]


def norm(s):
    s = re.sub(r"\n\[lines \d+-\d+ of \d+; use offset=\d+ to continue\]$", "", s.rstrip("\n"))
    return [re.sub(r"^(\d+→)+", "", l) for l in s.split("\n")]


own = back.rstrip("\n").rsplit("\n", 1)
assert own[1].startswith("[time "), own[1]  # this read's own budget line
nb = norm(own[0])
assert norm(orig)[-1].startswith("[time "), norm(orig)[-1]  # the original's budget line came back too
assert norm(orig) == nb, (norm(orig)[-3:], nb[-3:], len(norm(orig)), len(nb))
