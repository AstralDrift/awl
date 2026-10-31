#!/bin/bash
# awl with the old context strategy (a model-written summary at 80%), for the retrieval A/B.
AWL_COMPACT=summary exec "$(dirname "$0")/awl.sh" "$@"
