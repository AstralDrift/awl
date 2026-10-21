#!/bin/sh
[ "$(tr -d ' \n' < ANSWER.txt 2>/dev/null | sed 's#^\./##')" = "pkg3/mod5/f15.py" ]
