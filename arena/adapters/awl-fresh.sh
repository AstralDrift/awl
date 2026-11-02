#!/bin/bash
# awl with AWL_CTX_MODE=fresh (no summary: a fresh context that points at the session view), for the context A/B.
AWL_CTX_MODE=fresh exec "$(dirname "$0")/awl.sh" "$@"
