#!/bin/bash
. "$(dirname "$0")/common.sh"
AWL=${AWL_BIN:-$(dirname "$0")/../../zig-out/bin/awl}
XDG_STATE_HOME=$STATE/awl AWL_URL=$BASE AWL_MODEL=$MODEL AWL_KEY=$KEY exec "$AWL" -p "$PROMPT"
