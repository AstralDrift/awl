#!/bin/sh
[ "$(echo 'b a c a' | python3 words.py | tr '\n' ' ')" = "a b c " ] || exit 1
[ "$(echo 'b a c a' | python3 words.py --reverse | tr '\n' ' ')" = "c b a " ]
