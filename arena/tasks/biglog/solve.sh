#!/bin/sh
python3 - <<'P'
p = "money/amounts.py"; s = open(p).read()
s = s.replace('''    if code in COMMA_DECIMAL and "," in num:
        num = num.replace(",", ".")''', '''    if code in COMMA_DECIMAL and "," in num:
        num = num.replace(".", "").replace(",", ".")''')
open(p, "w").write(s)
P
