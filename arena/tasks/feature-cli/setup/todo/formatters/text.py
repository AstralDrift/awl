def render(tasks):
    if not tasks:
        return "nothing to do\n"
    lines = []
    for t in tasks:
        mark = "x" if t.done else " "
        due = f"  (due {t.due})" if t.due else ""
        lines.append(f"[{mark}] #{t.id} {t.title}{due}")
    return "\n".join(lines) + "\n"
