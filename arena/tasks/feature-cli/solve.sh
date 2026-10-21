#!/bin/sh
cat > todo/formatters/json_fmt.py <<'P'
import json


def render(tasks):
    return json.dumps([t.to_dict() for t in tasks], ensure_ascii=False) + "\n"
P
sed -i 's/from todo.formatters import csv_fmt, text/from todo.formatters import csv_fmt, json_fmt, text/; s/    "csv": csv_fmt.render,/    "csv": csv_fmt.render,\n    "json": json_fmt.render,/' todo/formatters/__init__.py
sed -i 's/choices=\["text", "csv"\], help="output format: text (default) or csv"/choices=["text", "csv", "json"], help="output format: text (default), csv or json"/' todo/cli.py
sed -i 's/--format text|csv/--format text|csv|json/' README.md
cat >> tests/test_cli.py <<'P'


class JsonTest(CliTest):
    def test_json(self):
        self.run_cli("add", "a")
        self.assertEqual(self.run_cli("list", "--format", "json")[1], '[{"id": 1, "title": "a", "done": false, "due": null}]\n')
P
