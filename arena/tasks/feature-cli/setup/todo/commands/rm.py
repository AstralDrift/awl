def run(store, args, out):
    tasks = store.load()
    keep = [t for t in tasks if t.id != args.id]
    if len(keep) == len(tasks):
        out.write(f"no task #{args.id}\n")
        return 1
    store.save(keep)
    out.write(f"removed #{args.id}\n")
    return 0
