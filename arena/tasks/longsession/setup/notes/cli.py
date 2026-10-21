import argparse
import datetime
import sys

from notes.export import to_markdown
from notes.model import Note
from notes.store import Store


def cmd_add(store, args, out):
    notes = store.load()
    nid = max((n.id for n in notes), default=0) + 1
    created = datetime.datetime.now().isoformat(timespec="seconds")
    notes.append(Note(nid, args.title, args.body or "", created, args.tag or []))
    store.save(notes)
    out.write(f"added {nid}\n")
    return 0


def line(n):
    tags = f"  [{', '.join(n.tags)}]" if n.tags else ""
    return f"{n.id:>3}  {n.title}{tags}"


def cmd_list(store, args, out):
    notes = store.load()
    if args.tag:
        notes = [n for n in notes if args.tag in n.tags]
    for n in notes:
        out.write(line(n) + "\n")
    return 0


def find(notes, nid, out):
    for n in notes:
        if n.id == nid:
            return n
    out.write(f"no note {nid}\n")
    return None


def cmd_show(store, args, out):
    n = find(store.load(), args.id, out)
    if not n:
        return 1
    out.write(f"{n.title}\n{n.created}\n\n{n.body}\n")
    return 0


def cmd_rm(store, args, out):
    notes = store.load()
    if not find(notes, args.id, out):
        return 1
    store.save([n for n in notes if n.id != args.id])
    out.write(f"removed {args.id}\n")
    return 0


def cmd_export(store, args, out):
    out.write(to_markdown(store.load()))
    return 0


def parser():
    p = argparse.ArgumentParser(prog="notes")
    p.add_argument("--db", default="notes.json")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("title")
    a.add_argument("body", nargs="?")
    a.add_argument("--tag", action="append")
    ls = sub.add_parser("list")
    ls.add_argument("--tag")
    for name in ("show", "rm"):
        s = sub.add_parser(name)
        s.add_argument("id", type=int)
    sub.add_parser("export")
    return p


COMMANDS = {"add": cmd_add, "list": cmd_list, "show": cmd_show, "rm": cmd_rm, "export": cmd_export}


def main(argv=None, out=sys.stdout):
    args = parser().parse_args(argv)
    return COMMANDS[args.cmd](Store(args.db), args, out)
