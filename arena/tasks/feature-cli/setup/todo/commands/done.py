def run(store, args, out):
    tasks = store.load()
    for t in tasks:
        if t.id == args.id:
            t.done = True
            store.save(tasks)
            out.write(f"done #{t.id}\n")
            return 0
    out.write(f"no task #{args.id}\n")
    return 1
