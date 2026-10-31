#!/usr/bin/env python3
"""Write a long synthetic awl session (OUT.jsonl) and its recall questions (OUT.questions.json).

A ledger-debugging task with 12 planted facts (an exact error, paths, numbers, a decision and its
reason, a user preference) among ~140 messages of ordinary work. Six facts come early (messages
1-20) and six late, 7-12 reads from the end. At a reset with a ~16K window the kept tail is the last
~3 reads, so all 12 are dropped from context; the summary request (AWL_COMPACT=summary) shows the
summarizer message 0 plus the newest messages that fit in ~2x the window, so it sees the late six
but never the early six. arena/recall.py reports which is which. Synthetic, not a real transcript:
the facts sit where a real session has them (tool output, the model's words, the user's words).
Usage: make_session.py OUT [--filler N]
"""
import json
import sys

out = sys.argv[1]
filler = int(sys.argv[sys.argv.index("--filler") + 1]) if "--filler" in sys.argv else 60
msgs = []
cid = 0
QS = []


def call(name, args, output, say=""):
    global cid
    cid += 1
    msgs.append({"role": "assistant", "content": say, "tool_calls": [{"id": f"c{cid}", "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}]})
    msgs.append({"role": "tool", "tool_call_id": f"c{cid}", "content": output})


def fact(q, a):
    QS.append({"q": q, "a": a})


# early: messages 1-20
msgs.append({"role": "user", "content": "The ledger tests are failing after the last merge. Find out why and fix it."})
call("bash", {"command": "python -m pytest -q"}, "==================== ERRORS ====================\n_____ ERROR collecting tests/test_ledger.py _____\nImportError: cannot import name 'parse_ledger' from 'ledger.core' (/work/app/ledger/core.py)\n1 error in 0.41s\n[exit 2]")
fact("What was the exact ImportError when the tests first ran?", "ImportError: cannot import name 'parse_ledger' from 'ledger.core' (/work/app/ledger/core.py)")
call("grep", {"pattern": "def parse_"}, "ledger/core.py:88:def parse_entries(text):\nledger/io.py:12:def parse_header(line):", "parse_ledger was renamed to parse_entries.")
call("edit", {"path": "ledger/__init__.py", "old_string": "parse_ledger", "new_string": "parse_entries"}, "edited ledger/__init__.py (1 change)")
call("bash", {"command": "python -m pytest -q"}, "FAILED tests/test_rounding.py::test_half_even_negative - assert Decimal('-2.4') == Decimal('-2.5')\n1 failed, 211 passed in 3.02s\n[exit 1]")
fact("Which test failed first after the import was fixed? Give its full pytest id.", "tests/test_rounding.py::test_half_even_negative")
call("bash", {"command": "python -m pytest -x -k half_even"}, "FAILED tests/test_rounding.py::test_half_even_negative\n1 failed, 3 deselected in 0.21s\n[exit 1]", "Fastest repro: python -m pytest -x -k half_even")
fact("Which exact command reproduced the failure fastest?", "python -m pytest -x -k half_even")
call("bash", {"command": "git log --oneline -5 -- ledger/round.py"}, "a3f9c2e round: use ROUND_HALF_UP for negative amounts\n7d01b44 round: add banker's rounding\n19ce0a2 initial import")
fact("Which commit introduced the rounding regression? Give the short hash.", "a3f9c2e")
call("read", {"path": "ledger/round.py", "offset": 135, "limit": 15}, "135→def round_amount(x, places=2):\n    q = Decimal(10) ** -places\n    if x < 0:\n        # a3f9c2e\n        return x.quantize(q, rounding=ROUND_HALF_UP)\n140→    return x.quantize(q, rounding=ROUND_HALF_EVEN)\n", "The bug is at ledger/round.py:142: negative amounts use ROUND_HALF_UP since a3f9c2e.")
fact("At which file and line is the rounding bug? Answer as path:line.", "ledger/round.py:142")
call("bash", {"command": "grep -rn STRICT app/ | head"}, "app/config.py:31:    strict = os.environ.get('LEDGER_STRICT_MODE') == '1'")
fact("Which environment variable turns on strict mode?", "LEDGER_STRICT_MODE")
msgs.append({"role": "user", "content": "Go on."})


def filler_read(i):
    body = "".join(f"    line {k}: amount = Decimal('{k}.{i % 10}5'); total += amount  # module {i}\n" for k in range(60))
    call("read", {"path": f"ledger/mod{i:03d}.py"}, body)


# late: 7-12 reads from the end, first in each message (a summary transcript cuts long tool output to its head and tail)
late = {
    filler - 12: lambda: call("bash", {"command": "APP_ENV=prod python -c 'import app.config as c; print(c.loaded_from())'"}, "/work/app/conf/settings.prod.toml"),
    filler - 11: lambda: call("bash", {"command": "grep -n pydantic requirements.txt"}, "4:pydantic==2.7.4"),
    filler - 10: lambda: call("bash", {"command": "python -m app.server --port 8743 & sleep 1; python bench.py"}, "server listening on http://127.0.0.1:8743\nrequests: 2000  p50 112.3 ms  p95 418.7 ms  p99 902.0 ms"),
    filler - 9: lambda: msgs.append({"role": "assistant", "content": "Decision: keep SQLite instead of moving to Postgres, because the deploy target has no network access."}),
    filler - 8: lambda: msgs.append({"role": "user", "content": "Agreed. And when you touch the Makefile: tabs, not spaces, please."}),
}
for i in range(filler):  # ordinary work: big reads, no new facts
    late[i]() if i in late else filler_read(i)
fact("Which config file did the app load in production mode? Give the full path.", "/work/app/conf/settings.prod.toml")
fact("Which pydantic version is pinned?", "2.7.4")
fact("On which port did the dev server listen?", "8743")
fact("What p95 latency did the benchmark report?", "418.7 ms")
fact("Which database did we decide to keep, and why? Quote the reason.", "the deploy target has no network access")
fact("What did the user ask for about indentation in the Makefile?", "tabs, not spaces")
msgs.append({"role": "assistant", "content": "All modules read; continuing with the fix."})
with open(out, "w") as f:  # compact, as awl writes it (awl matches its own '{"role":"assistant"' prefix)
    f.write(json.dumps({"awl": "recall-fixture", "model": "fixture", "cwd": "/work/app"}, separators=(",", ":")) + "\n")
    for m in msgs:
        f.write(json.dumps(m, separators=(",", ":"), ensure_ascii=False) + "\n")
json.dump(QS, open(out.rsplit(".", 1)[0] + ".questions.json", "w"), indent=1)
print(f"{out}: {len(msgs)} messages, {sum(len(json.dumps(m)) for m in msgs)} bytes; {len(QS)} questions")
