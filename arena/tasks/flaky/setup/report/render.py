"""Plain-text rendering of the daily report."""
import datetime


def tags_line(tags):
    """Unique tags, comma separated, in alphabetical order."""
    return ", ".join(set(tags))


def header(title):
    today = datetime.datetime.utcnow().date()
    return f"{title} — {today.isoformat()}"


def item_line(item):
    return f"#{item['id']:<3} {item['title']}"


def render(title, items):
    from report.data import all_tags
    lines = [header(title), ""]
    lines += [item_line(it) for it in items]
    lines += ["", "tags: " + tags_line(all_tags(items))]
    return "\n".join(lines) + "\n"
