#!/bin/bash
. "$(dirname "$0")/common.sh"
ag=$STATE/omp
pi_models "$ag"
cp -f "$ag/models.json" "$ag/models.yml"
printf 'modelRoles:\n  default: omarchy-local/%s\nsetupVersion: 2\n' "$MODEL" >"$ag/config.yml"
PI_CODING_AGENT_DIR=$ag OMP_CODING_AGENT_DIR=$ag OMP_NO_WEBP=1 exec omp --provider omarchy-local --model "$MODEL" \
  --thinking medium --print --auto-approve --approval-mode=yolo --no-session --cwd "$WD" "$PROMPT"
