from todo.model import Task


def run(store, args, out):
    tasks = store.load()
    t = Task(id=store.next_id(tasks), title=args.title, due=args.due)
    tasks.append(t)
    store.save(tasks)
    out.write(f"added #{t.id}\n")
    return 0
