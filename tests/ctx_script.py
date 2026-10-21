#!/usr/bin/env python3
"""Fake-model script for the elision test: 12 big reads with a growing prompt, then done."""
import json
import sys

t = [{"tool_calls": [{"name": "read", "arguments": {"path": "big.txt"}}],
      "usage": {"prompt_tokens": 500 + 100 * i, "completion_tokens": 5}} for i in range(12)]
t.append({"content": "done"})
json.dump(t, open(sys.argv[1], "w"))
