#!/bin/sh
cc -o /tmp/awl-arena-sum-$$ sum.c 2>/dev/null || exit 1
out=$(/tmp/awl-arena-sum-$$ | tr '\n' ' '); rm -f /tmp/awl-arena-sum-$$
[ "$out" = "31 8 " ]
