#!/usr/bin/env python3
"""Fake-model script for the elision test: 12 big reads with a growing prompt (60-80% of a 1500
token window: elision, no reset), then one read of
the first elided output where its marker says it is (the session view), then done."""
import json
import sys

t = [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}],
      "usage": {"prompt_tokens": min(500 + 100 * i, 1150), "completion_tokens": 5}} for i in range(12)]
t.append({"tool_calls": [{"name": "read", "arguments": {"path": "$VIEW", "offset": "$ELIDED_OFFSET", "limit": "$ELIDED_LIMIT"}}],
          "usage": {"prompt_tokens": 1000, "completion_tokens": 5}})
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
