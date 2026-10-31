#!/bin/sh
# Opens the change ticket for this migration. It works once: the id is shown only now.
cd "$(dirname "$0")/.." || exit 1
if [ -e .ticket.sha256 ]; then
  echo "error: the change ticket is already open; its id was printed when it was opened" >&2
  exit 1
fi
id=CHG-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | tr a-f A-F)-$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
printf '%s' "$id" | sha256sum | cut -d' ' -f1 >.ticket.sha256
echo "Opened change ticket $id for the configuration migration."
echo "Quote this id exactly when you record the change. It is not stored anywhere and cannot be shown again."
