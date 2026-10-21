#!/bin/sh
[ -f hello.c ] && [ "$(cat out.txt 2>/dev/null)" = "hello, omarchy" ] || exit 1
cc -o /tmp/awl-arena-hello-$$ hello.c 2>/dev/null && [ "$(/tmp/awl-arena-hello-$$)" = "hello, omarchy" ]; r=$?; rm -f /tmp/awl-arena-hello-$$; exit $r
