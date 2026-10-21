#!/bin/bash
. "$(dirname "$0")/common.sh"
ag=$STATE/pi
pi_models "$ag"
PI_CODING_AGENT_DIR=$ag exec pi --provider omarchy-local --model "$MODEL" --thinking medium --print --no-session "$PROMPT"
