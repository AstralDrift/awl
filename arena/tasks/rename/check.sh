#!/bin/sh
python3 test_app.py >/dev/null 2>&1 || exit 1
! grep -rq calc_total --include=*.py . && grep -q "def order_total" app/util.py
