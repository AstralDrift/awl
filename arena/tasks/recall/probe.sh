#!/bin/sh
# Recall probe: the ticket id was printed once at the start and is needed only at the end.
[ -f .ticket.sha256 ] || { echo "ticket never opened"; exit 1; }
id=$(sed -n 's/^Ticket: *\([^ ]*\) *$/\1/p' docs/CHANGELOG.md 2>/dev/null | head -1)
[ -n "$id" ] || { echo "no 'Ticket: <id>' line in docs/CHANGELOG.md"; exit 1; }
[ "$(printf '%s' "$id" | sha256sum | cut -d' ' -f1)" = "$(cat .ticket.sha256)" ] || { echo "wrong ticket id: $id"; exit 1; }
echo ok
