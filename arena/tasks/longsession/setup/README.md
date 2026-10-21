# notes

Command-line notes stored in a JSON file with a schema version and migrations.

    python3 -m notes --db notes.json add "Title" "body text" [--tag work]
    python3 -m notes --db notes.json list [--tag work]
    python3 -m notes --db notes.json show 3
    python3 -m notes --db notes.json rm 3
    python3 -m notes --db notes.json export > notes.md

Data format: `{"version": N, "notes": [...]}`. Older files are migrated on load (see notes/migrations.py).
Tests: `python3 -m unittest discover -s tests`
