"""Tiny TTL cache for computed values."""
import time

_entries = {}
TTL = 5.0


def get(key):
    hit = _entries.get(key)
    if hit and time.monotonic() - hit[0] < TTL:
        return hit[1]
    return None


def put(key, value):
    _entries[key] = (time.monotonic(), value)


def cached(key, compute):
    value = get(key)
    if value is None:
        put(key, compute)
    return get(key)
