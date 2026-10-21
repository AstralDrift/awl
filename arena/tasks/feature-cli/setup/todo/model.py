from dataclasses import dataclass
from typing import Optional


@dataclass
class Task:
    id: int
    title: str
    done: bool = False
    due: Optional[str] = None  # ISO date

    def to_dict(self):
        return {"id": self.id, "title": self.title, "done": self.done, "due": self.due}

    @staticmethod
    def from_dict(d):
        return Task(id=d["id"], title=d["title"], done=d.get("done", False), due=d.get("due"))
