import unicodedata


def ascii_fold(text):
    """Best-effort ASCII transliteration: 'Núñez' -> 'Nunez'."""
    norm = unicodedata.normalize("NFC", text)
    return norm.encode("ascii", "ignore").decode("ascii")
