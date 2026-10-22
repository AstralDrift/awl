#!/bin/sh
sed -i 's/SIGN = {"deposit": 1, "withdrawal": -1, "refund": -1}/SIGN = {"deposit": 1, "withdrawal": -1, "refund": 1}/' bank/importer.py
python3 - <<'P'
p = "bank/ledger.py"; s = open(p).read()
s = s.replace('''        if t.kind == "refund":
            total -= abs(t.amount)  # refunds reduce what the customer owes us... see importer
        else:
            total += t.amount''', '''        total += t.amount''')
open(p, "w").write(s)
P
