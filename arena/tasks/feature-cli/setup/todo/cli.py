import argparse
import os
import sys

from todo.commands import add, done, list as list_cmd, rm
from todo.store import Store

COMMANDS = {"add": add.run, "list": list_cmd.run, "done": done.run, "rm": rm.run}


def parser():
    p = argparse.ArgumentParser(prog="todo", description="Tiny todo list.")
    p.add_argument("--db", default=os.path.expanduser("~/.todo.json"), help="data file")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("add", help="add a task")
    a.add_argument("title")
    a.add_argument("--due", help="due date, YYYY-MM-DD")

    ls = sub.add_parser("list", help="list tasks")
    g = ls.add_mutually_exclusive_group()
    g.add_argument("--pending", action="store_true", help="only open tasks")
    g.add_argument("--done", action="store_true", help="only finished tasks")
    ls.add_argument("--format", default="text", choices=["text", "csv"], help="output format: text (default) or csv")

    d = sub.add_parser("done", help="mark a task done")
    d.add_argument("id", type=int)

    r = sub.add_parser("rm", help="remove a task")
    r.add_argument("id", type=int)
    return p


def main(argv=None, out=sys.stdout):
    args = parser().parse_args(argv)
    return COMMANDS[args.cmd](Store(args.db), args, out)
