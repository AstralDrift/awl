from dataclasses import dataclass, field
from typing import List


@dataclass
class Note:
    id: int
    title: str
    body: str = ""
    created: str = ""  # ISO timestamp
    tags: List[str] = field(default_factory=list)
