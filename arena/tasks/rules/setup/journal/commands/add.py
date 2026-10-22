from journal import clock


def run(store, args):
    entries = store.load("entries.json", [])
    entries.append({"at": clock.now().isoformat(timespec="seconds"), "text": " ".join(args)})
    store.save("entries.json", entries)
    return f"added entry {len(entries)}"
