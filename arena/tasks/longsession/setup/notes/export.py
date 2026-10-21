"""Markdown export."""


def to_markdown(notes):
    out = []
    for n in notes:
        tags = f" _({', '.join(n.tags)})_" if n.tags else ""
        out.append(f"## {n.title}{tags}\n\n{n.body}\n")
    return "\n".join(out)
