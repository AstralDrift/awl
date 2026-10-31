#!/bin/bash
# awl with AWL_CTX_MODE=async (background same-prefix summary at 70%, swapped in at 80%), for the context A/B.
AWL_CTX_MODE=async exec "$(dirname "$0")/awl.sh" "$@"
