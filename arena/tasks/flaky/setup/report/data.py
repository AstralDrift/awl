"""Sample data for the daily report."""

ITEMS = [
    {"id": 1, "title": "Ship release", "tags": ["release", "ops", "release"]},
    {"id": 2, "title": "Fix login", "tags": ["auth", "bug"]},
    {"id": 3, "title": "Write docs", "tags": ["docs"]},
]


def all_tags(items):
    tags = []
    for it in items:
        tags.extend(it["tags"])
    return tags
