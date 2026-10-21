"""User handles: lowercase ascii, words joined by '-'."""
from core.text import ascii_fold, slugify

RESERVED = {"admin", "root", "support", "api"}


def make_handle(display_name, taken=()):
    base = slugify(ascii_fold(display_name.replace("'", ""))) or "user"
    if base in RESERVED:
        base += "-user"
    handle, n = base, 2
    while handle in taken:
        handle = f"{base}-{n}"
        n += 1
    return handle
