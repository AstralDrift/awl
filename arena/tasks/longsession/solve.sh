#!/bin/sh
python3 - <<'P'
def sub(p, a, b):
    s = open(p).read()
    assert a in s, (p, a)
    open(p, "w").write(s.replace(a, b, 1))

sub("notes/model.py", "    tags: List[str] = field(default_factory=list)\n", "    tags: List[str] = field(default_factory=list)\n    pinned: bool = False\n")
sub("notes/serialize.py", '"tags": list(n.tags)}', '"tags": list(n.tags), "pinned": n.pinned}')
sub("notes/serialize.py", 'tags=list(d.get("tags", [])))', 'tags=list(d.get("tags", [])), pinned=bool(d.get("pinned", False)))')
sub("notes/migrations.py", "CURRENT = 2", "CURRENT = 3")
sub("notes/migrations.py", "STEPS = {0: v0_to_v1, 1: v1_to_v2}", '''def v2_to_v3(data):
    for n in data["notes"]:
        n.setdefault("pinned", False)
    data["version"] = 3
    return data


STEPS = {0: v0_to_v1, 1: v1_to_v2, 2: v2_to_v3}''')
sub("notes/cli.py", '''    return f"{n.id:>3}  {n.title}{tags}"''', '''    pin = "*" if n.pinned else " "
    return f"{n.id:>3}{pin} {n.title}{tags}"''')
sub("notes/cli.py", '''    for n in notes:
        out.write(line(n) + "\\n")''', '''    for n in sorted(notes, key=lambda n: (not n.pinned, n.id)):
        out.write(line(n) + "\\n")''')
sub("notes/cli.py", '''def cmd_export(''', '''def set_pin(store, args, out, value):
    notes = store.load()
    n = find(notes, args.id, out)
    if not n:
        return 1
    n.pinned = value
    store.save(notes)
    out.write(f"{'pinned' if value else 'unpinned'} {args.id}\\n")
    return 0


def cmd_export(''')
sub("notes/cli.py", '''    for name in ("show", "rm"):''', '''    for name in ("show", "rm", "pin", "unpin"):''')
sub("notes/cli.py", '''"export": cmd_export}''', '''"export": cmd_export,
            "pin": lambda s, a, o: set_pin(s, a, o, True), "unpin": lambda s, a, o: set_pin(s, a, o, False)}''')
sub("tests/test_notes.py", 'self.assertEqual(data["version"], 2)', 'self.assertEqual(data["version"], 3)\n        self.assertEqual(data["notes"][0]["pinned"], False)')
sub("tests/test_notes.py", '''    def test_export(self):''', '''    def test_pin(self):
        self.cli("add", "a")
        self.cli("add", "b")
        self.assertEqual(self.cli("pin", "2"), (0, "pinned 2\\n"))
        self.assertEqual(self.cli("list")[1], "  2* b\\n  1  a\\n")

    def test_export(self):''')
sub("CHANGELOG.md", "## Unreleased\n", "## Unreleased\n- Pin notes: `pin ID` / `unpin ID`; pinned notes list first, marked `*`. Schema v3.\n")
P
