from todo.formatters import FORMATTERS


def select(tasks, args):
    if args.pending:
        return [t for t in tasks if not t.done]
    if args.done:
        return [t for t in tasks if t.done]
    return tasks


def run(store, args, out):
    tasks = select(store.load(), args)
    out.write(FORMATTERS[args.format](tasks))
    return 0
