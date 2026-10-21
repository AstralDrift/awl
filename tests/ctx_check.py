#!/usr/bin/env python3
"""Assert the last request elided the oldest tool outputs and kept the newest."""
import json
import sys

m = [json.loads(l) for l in open(sys.argv[1])][-1]["messages"]
tools = [x["content"] for x in m if x["role"] == "tool"]
assert any(c.startswith("[old tool output elided") for c in tools), "nothing elided"
assert not tools[-1].startswith("[old"), "newest output elided"
assert tools[0].startswith("[old"), "oldest output kept"
assert all(x.get("tool_call_id") for x in m if x["role"] == "tool")
