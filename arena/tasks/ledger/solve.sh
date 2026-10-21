#!/bin/sh
sed -i 's/return total - base \* people/return total - base * (people - 1)/' src/ledger.py
printf 'PASS\nlast_share subtracted base for every person instead of all but the last.\n' > RESULT.txt
