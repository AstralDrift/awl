#!/bin/sh
cat > journal/commands/archive.py <<'P'
import datetime

from journal import clock


def run(store, args):
    days = int(args[0]) if args else 30
    cutoff = clock.now() - datetime.timedelta(days=days)
    entries = store.load("entries.json", [])
    old = [e for e in entries if datetime.datetime.fromisoformat(e["at"]) < cutoff]
    keep = [e for e in entries if e not in old]
    store.save("archive.json", store.load("archive.json", []) + old)
    store.save("entries.json", keep)
    return f"archived {len(old)} entries"
P
sed -i 's/from journal.commands import add, list as list_/from journal.commands import add, archive, list as list_/; s/COMMANDS = {"add": add.run, "list": list_.run}/COMMANDS = {"add": add.run, "list": list_.run, "archive": archive.run}/' journal/commands/__init__.py
echo '- `archive [DAYS]`: move entries older than DAYS (default 30) to archive.json.' >> docs/commands.md
cat >> tests/test_journal.py <<'P'


class ArchiveTest(JournalTest):
    def test_archive(self):
        self.store.save("entries.json", [{"at": "2026-08-01T00:00:00", "text": "old"}])
        self.assertEqual(COMMANDS["archive"](self.store, []), "archived 1 entries")
P
