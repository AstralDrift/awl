import json
import os

from notes import migrations, serialize


class Store:
    def __init__(self, path):
        self.path = path

    def load(self):
        if not os.path.exists(self.path):
            return []
        with open(self.path) as f:
            data = migrations.migrate(json.load(f))
        return [serialize.from_dict(d) for d in data["notes"]]

    def save(self, notes):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"version": migrations.CURRENT, "notes": [serialize.to_dict(n) for n in notes]}, f, indent=1, ensure_ascii=False)
        os.replace(tmp, self.path)
