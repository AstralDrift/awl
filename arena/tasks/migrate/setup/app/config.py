"""Configuration.

Old style (being removed): the module-level `settings` dict, raw strings, accessed as
settings["key"] or settings.get("key", default) all over the code base.
New style: `load_config()` returns a typed `Config`. Use it everywhere.
"""
import configparser
import os
from dataclasses import dataclass, field

_PATH = os.path.join(os.path.dirname(__file__), "..", "settings.ini")


@dataclass(frozen=True)
class Config:
    db_url: str
    timeout: int
    region: str
    retries: int
    feature_flags: frozenset = field(default_factory=frozenset)


def load_config(path=_PATH):
    cp = configparser.ConfigParser()
    cp.read(path)
    a = cp["app"]
    flags = frozenset(f.strip() for f in a.get("feature_flags", "").split(",") if f.strip())
    return Config(db_url=a["db_url"], timeout=int(a["timeout"]), region=a["region"], retries=int(a["retries"]), feature_flags=flags)


# --- old style, to be deleted once nothing uses it ---
def _load_settings(path=_PATH):
    cp = configparser.ConfigParser()
    cp.read(path)
    return dict(cp["app"])


settings = _load_settings()
