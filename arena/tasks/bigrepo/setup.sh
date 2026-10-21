#!/bin/sh
# Generates the bulk of the repo: 250 service modules, their tests, and vendored/legacy helpers
# (several define their own ascii_fold, some right and some wrong; none are imported by accounts).
python3 - <<'P'
import os, random
rng = random.Random(7)
words = "order cart user invoice ship stock price promo review search email audit report token session cache queue export import billing refund coupon tax address".split()
os.makedirs("services", exist_ok=True)
open("services/__init__.py", "w").close()
for i in range(250):
    a, b = rng.sample(words, 2)
    name = f"svc_{i:03d}_{a}_{b}"
    fns = []
    for j in range(6):
        verb = rng.choice(["load", "save", "check", "merge", "split", "score", "render", "count"])
        fns.append(f'''
def {verb}_{a}_{j}(items, limit={rng.randint(5, 500)}):
    """{verb.title()} {a} records for the {b} pipeline (step {j})."""
    out = []
    for n, item in enumerate(items):
        if n >= limit:
            break
        key = str(item.get("{a}_id", n)).strip().lower()
        if key and not key.startswith("{b[:2]}"):
            out.append({{"key": key, "{b}": item.get("{b}"), "rank": n * {rng.randint(1, 9)}}})
    return sorted(out, key=lambda r: r["rank"])
''')
    open(f"services/{name}.py", "w").write(f'"""Service: {a} x {b}."""\n' + "".join(fns))
for i in range(40):
    kind = rng.choice(["vendor", "legacy"])
    d = f"{kind}/pkg{i:02d}"
    os.makedirs(d, exist_ok=True)
    open(f"{d}/__init__.py", "w").close()
    form = rng.choice(["NFKD", "NFC", "NFKD", "NFD"])
    open(f"{d}/text.py", "w").write(f'''"""Vendored text helpers ({kind} copy #{i}). Not used by hub code."""
import unicodedata


def ascii_fold(text):
    return unicodedata.normalize("{form}", text).encode("ascii", "ignore").decode("ascii")


def slugify(text):
    return "-".join(w for w in ascii_fold(text).lower().split() if w)
''')
P
