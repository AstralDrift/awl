import csv
import io


def render(tasks):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["id", "title", "done", "due"])
    for t in tasks:
        w.writerow([t.id, t.title, "yes" if t.done else "no", t.due or ""])
    return buf.getvalue()
