#!/usr/bin/env python3
"""AWL_CTX_MODE=async, from the fake server's log (--raw 1).
  async_check.py LOG swap      the summary request is the step request it ran beside plus one message, byte
                               for byte; the swap keeps every message made after it started, once each
  async_check.py LOG fallback  the background summary failed or was late: A's serialized summary request ran,
                               and the run went on"""
import json
import re
import sys

reqs = [json.loads(l) for l in open(sys.argv[1])]
ask = "[awl: the conversation above is about to exceed"
summ = [i for i, r in enumerate(reqs) if str(r["messages"][-1].get("content", "")).startswith(ask)]
assert len(summ) == 1, f"{len(summ)} background summary requests"
S = reqs[summ[0]]
assert "tool_choice" not in S, "tool_choice would change the rendered prompt"
assert S["tools"], "tools left out of the summary request"
steps = [r for i, r in enumerate(reqs) if i not in summ and not str(r["messages"][-1].get("content", "")).startswith("The conversation below")]
# the step request with the same history: the summary is it plus the one message
twin = [r for r in steps if r["messages"] == S["messages"][:-1]]
assert twin, "no step request has the summary request's history"
raw_s, raw_t = S["_raw"], twin[0]["_raw"]
cut = raw_s.index(',{"role":"user","content":"[awl: the conversation above')
strip = lambda b: re.sub(r'"max_tokens":\s*\d+', "", b)  # sized per request from its length; not part of the prompt
assert strip(raw_s[:cut]) == strip(raw_t[:cut]), "summary request is not the step request's bytes up to the new message"
assert raw_t[cut] == "]", raw_t[cut - 20:cut + 20]  # ...and the step request ends its messages right there
if sys.argv[2] == "fallback":
    a = [r for r in reqs if str(r["messages"][-1].get("content", "")).startswith("The conversation below")]
    assert len(a) == 1, f"{len(a)} serialized summary requests"
    assert steps[-1]["messages"][2]["content"].startswith("[Earlier work, summarized"), steps[-1]["messages"][2]["content"][:80]
    sys.exit(0)
# swap: the first step request after the swap
after = [r for r in steps if len(r["messages"]) > 3 and r["messages"][2]["role"] == "user" and str(r["messages"][2]["content"]).startswith("[Earlier work, summarized")]
assert after, "no request after a swap"
R = after[0]
sm = R["messages"][2]["content"]
assert "SUMMARY-FROM-BACKGROUND" in sm, sm[:200]
assert re.search(r"plain-text log /\S+/view-\d+\.txt", sm), sm[-300:]
assert R["messages"][1] == S["messages"][1], "the task is not first"
tail = R["messages"][3:]
covered = len(S["messages"]) - 1  # messages the summary covers
before = [r for r in steps if len(r["messages"]) > covered and r["messages"][:covered] == S["messages"][:covered]]
newest = max(before, key=lambda r: len(r["messages"]))  # the last step request before the swap
made_after = newest["messages"][covered:]
assert tail[: len(made_after)] == made_after, "a message made after the summary started is missing or changed"
assert len(tail) == len(made_after) + 2, (len(tail), len(made_after))  # + the last step's call and result
sig = [json.dumps(m, sort_keys=True) for m in R["messages"]]
assert len(sig) == len(set(sig)), "a message appears twice"
assert sum("MID1" in x for x in sig) == 2 and sum("MID2" in x for x in sig) == 2, "a call or result made after the start is lost or doubled"
for i, m in enumerate(tail):  # every result right after the call it answers (ids repeat across turns in the fake)
    if m["role"] == "tool":
        prev = next(x for x in reversed(tail[:i]) if x["role"] == "assistant")
        assert m["tool_call_id"] in [c["id"] for c in prev.get("tool_calls") or []], m
assert tail[0]["role"] == "assistant", tail[0]["role"]
