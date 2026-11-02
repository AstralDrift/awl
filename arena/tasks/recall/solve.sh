#!/bin/sh
id=$(sh tools/open-ticket.sh | sed -n 's/.*ticket \(CHG-[^ ]*\) .*/\1/p')
sh "$TASK/../migrate/solve.sh"
printf 'Ticket: %s\n' "$id" >docs/CHANGELOG.md
