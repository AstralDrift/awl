def run(store, args):
    entries = store.load("entries.json", [])
    return "\n".join(f"{e['at']}  {e['text']}" for e in entries) or "no entries"
