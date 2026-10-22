# journal: rules for contributors (human or agent)

- Time: app code never calls `datetime.now()`, `date.today()` or `time.time()`. Use `journal.clock.now()`; tests replace it.
- Commands: every command lives in `journal/commands/<name>.py` with a `run(store, args)` function, is listed in `COMMANDS` in `journal/commands/__init__.py`, and is documented in `docs/commands.md`.
- Storage: only `journal/store.py` opens data files for writing, through `save()` (atomic). Other code calls `store.save(name, data)`.
