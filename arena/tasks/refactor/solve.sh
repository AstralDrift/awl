#!/bin/sh
python3 - <<'P'
import os, re

def rewrite(src, name, new):
    out, i = [], 0
    pat = re.compile(r'(?<![\w.])' + re.escape(name) + r'\(|(?<=\.)' + re.escape(name) + r'\(')
    while True:
        m = pat.search(src, i)
        if not m:
            out.append(src[i:]); return "".join(out)
        start = m.end()
        depth, j, comma = 1, start, None
        while depth:
            c = src[j]
            if c in "([{": depth += 1
            elif c in ")]}": depth -= 1
            elif c == "," and depth == 1 and comma is None: comma = j
            j += 1
        args = src[start:j - 1]
        if comma is None:
            a, b = args.strip(), "'USD'"
        else:
            a, b = src[start:comma].strip(), src[comma + 1:j - 1].strip()
        out.append(src[i:m.start()] + new + "(" + b + ", " + a + ")")
        i = j

skip = {"src/admin/csv.js", "src/legacy/pos.js"}
for root in ("src", "test"):
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if p in skip: continue
            s = open(p).read()
            if "formatPrice" not in s: continue
            if "formatPrice: fp" in s:
                s = s.replace("formatPrice: fp", "formatMoney: fp")
                s = rewrite(s, "fp", "fp")
            s = rewrite(s, "formatPrice", "formatMoney")
            s = s.replace("{ formatPrice }", "{ formatMoney }").replace("{ formatPrice,", "{ formatMoney,")
            open(p, "w").write(s)
p = "lib/format.js"; s = open(p).read()
s = s.replace("formatPrice(1999, 'USD')", "formatMoney('USD', 1999)").replace("function formatPrice(amount, currency = 'USD')", "function formatMoney(currency, amount)")
s = s.replace("{ formatPrice, formatPercent }", "{ formatMoney, formatPercent }")
open(p, "w").write(s)
P
