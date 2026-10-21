#!/bin/sh
sed -i 's/s += a\[i - 1 + (i == n)\];/s += a[i - 1];/' sum.c
