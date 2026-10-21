# todo

Tiny todo list CLI. Data lives in a JSON file (`--db`, default `~/.todo.json`).

    python3 -m todo add "Buy milk" --due 2026-11-01
    python3 -m todo list [--pending | --done] [--format text|csv]
    python3 -m todo done 3
    python3 -m todo rm 3

Run tests: `python3 -m unittest discover -s tests`
