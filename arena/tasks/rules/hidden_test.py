import datetime
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.getcwd())
from journal import clock  # noqa: E402
from journal.commands import COMMANDS  # noqa: E402
from journal.store import Store  # noqa: E402

assert "archive" in COMMANDS, "archive not registered in COMMANDS"
d = tempfile.mkdtemp()
st = Store(d)
fixed = datetime.datetime(2026, 10, 21, 12, 0, 0)
clock.now = lambda: fixed  # the rule: app code must read time through clock.now()
st.save("entries.json", [
    {"at": "2026-08-01T10:00:00", "text": "old1"},
    {"at": "2026-09-25T10:00:00", "text": "mid"},
    {"at": "2026-10-20T10:00:00", "text": "new"},
])
st.save("archive.json", [{"at": "2026-01-01T00:00:00", "text": "ancient"}])
out = COMMANDS["archive"](st, [])
assert re.search(r"\b1\b", str(out)), f"default 30 days should move 1 entry, said {out!r}"
assert [e["text"] for e in st.load("entries.json", [])] == ["mid", "new"], st.load("entries.json", [])
assert [e["text"] for e in st.load("archive.json", [])] == ["ancient", "old1"], st.load("archive.json", [])
out = COMMANDS["archive"](st, ["7"])
assert re.search(r"\b1\b", str(out)), f"7 days should move 1 more entry, said {out!r}"
assert [e["text"] for e in st.load("entries.json", [])] == ["new"]
assert not [f for f in os.listdir(d) if f.endswith(".tmp")]

# rules from AGENTS.md
src = {p: open(p).read() for p in __import__("glob").glob("journal/**/*.py", recursive=True)}
for p, s in src.items():
    if p != "journal/clock.py":
        assert not re.search(r"datetime\.now\(|date\.today\(|time\.time\(", s), f"{p} reads the clock directly"
    if p != "journal/store.py":
        assert not re.search(r"open\([^)]*['\"][wa]", s), f"{p} writes a file directly"
assert os.path.exists("journal/commands/archive.py"), "command not in journal/commands/archive.py"
assert "archive" in open("docs/commands.md").read(), "archive not documented in docs/commands.md"
print("hidden ok")
