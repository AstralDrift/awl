#!/bin/sh
python3 - <<'P'
import glob, re
for p in glob.glob("app/services/*.py"):
    if p.endswith("__init__.py"):
        continue
    s = open(p).read()
    s = s.replace("from app.config import settings", "from app.config import load_config")
    s = s.replace("def describe():\n", "def describe():\n    cfg = load_config()\n")
    s = s.replace('settings["db_url"]', "cfg.db_url").replace('int(settings.get("timeout", 30))', "cfg.timeout")
    s = s.replace('settings.get("region", "us-east")', "cfg.region").replace('int(settings["retries"])', "cfg.retries")
    s = s.replace('[f.strip() for f in settings.get("feature_flags", "").split(",") if f.strip()]', "sorted(cfg.feature_flags)")
    s = s.replace('int(settings["timeout"])', "cfg.timeout").replace('settings["region"]', "cfg.region")
    s = s.replace("int(settings.get('retries', 1))", "cfg.retries")
    assert "settings" not in s, (p, s[-300:])
    open(p, "w").write(s)
p = "app/config.py"; s = open(p).read()
s = s[: s.index("# --- old style")]
s = s.replace('Old style (being removed): the module-level `settings` dict, raw strings, accessed as\nsettings["key"] or settings.get("key", default) all over the code base.\nNew style: `load_config()` returns a typed `Config`. Use it everywhere.', "Use `load_config()`, which returns a typed `Config`.")
open(p, "w").write(s)
open("docs/CONFIG.md", "w").write("# Configuration\n\nSettings live in `settings.ini`. In code, call `load_config()` from `app.config`;\nit returns a typed `Config` (`cfg.db_url`, `cfg.timeout`, `cfg.retries`, `cfg.region`, `cfg.feature_flags`).\n")
P
