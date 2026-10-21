import re

_SEP = re.compile(r"[^a-z0-9]+")


def collapse(text, sep="-"):
    return _SEP.sub(sep, text.lower()).strip(sep)


def slugify(text, max_len=40):
    return collapse(text)[:max_len].rstrip("-")
