"""Note <-> dict for the JSON store."""
from notes.model import Note


def to_dict(n):
    return {"id": n.id, "title": n.title, "body": n.body, "created": n.created, "tags": list(n.tags)}


def from_dict(d):
    return Note(id=d["id"], title=d["title"], body=d.get("body", ""), created=d.get("created", ""), tags=list(d.get("tags", [])))
