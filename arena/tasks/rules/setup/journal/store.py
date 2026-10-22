"""JSON files in the data directory. Writes are atomic."""
import json
import os


class Store:
    def __init__(self, root):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def load(self, name, default):
        p = os.path.join(self.root, name)
        if not os.path.exists(p):
            return default
        with open(p) as f:
            return json.load(f)

    def save(self, name, data):
        p = os.path.join(self.root, name)
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, p)
