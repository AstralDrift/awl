#!/bin/bash
# QA on the local model: awl works on a throwaway clone of its own repo, then the
# clone's own checks run. One task at a time (one GPU).
#
#   arena/qa.sh NAME            task files: arena/qa/NAME.txt (the prompt),
#                               NAME.setup.sh (optional, runs in the clone first),
#                               NAME.env (optional, e.g. AWL_MODE=plan)
#   arena/qa.sh NAME -c PROMPT  continue NAME's session in the same clone
#
# - The clone is /tmp/awl-qa/NAME with no git remote: nothing can be pushed.
# - Nothing hints at a planted bug: setup changes are folded into the clone's last commit.
# - Requests are logged under arena/results/qa/NAME/ (tokens, timings), with awl's answer,
#   its stderr, the diff, and the check results.
# - A guard stops awl (by PID) after QA_TIMEOUT seconds (default 1800), or when no request starts for 5 min.
set -eu
NAME=$1
shift
CONT=""
[ "${1:-}" = -c ] && { CONT=$2; shift 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
WD=/tmp/awl-qa/$NAME
OUT=$HERE/results/qa/$NAME
Z=$(cd "$REPO" && mise where zig) && export PATH="$Z:$PATH"
BIN=$OUT/awl # frozen copy: rebuilding the repo mid-run changes nothing
if [ -z "$CONT" ]; then
  [ -e "$WD" ] && { echo "qa: $WD exists; remove it or pick a new NAME"; exit 2; }
  mkdir -p /tmp/awl-qa "$OUT"
  (cd "$REPO" && zig build -Doptimize=ReleaseSmall)
  cp "$REPO/zig-out/bin/awl" "$BIN"
  git clone -q --no-hardlinks "$REPO" "$WD"
  git -C "$WD" remote remove origin
  [ -f "$HERE/qa/$NAME.setup.sh" ] && (cd "$WD" && bash "$HERE/qa/$NAME.setup.sh" && git add -A && git -c user.name=qa -c user.email=qa@localhost commit -q --amend --no-edit)
  git -C "$WD" rev-parse HEAD >"$OUT/base" # diffs are against this, so commits awl makes count
  PROMPT=$(cat "$HERE/qa/$NAME.txt")
  TAG=run
else
  PROMPT=$CONT
  TAG=cont
fi
ENV=() # NAME.env applies to awl only, not to the checks afterwards
[ -f "$HERE/qa/$NAME.env" ] && mapfile -t ENV < <(grep -v '^#' "$HERE/qa/$NAME.env" | grep .)

python3 "$HERE/proxy.py" --upstream http://127.0.0.1:12434 --out "$OUT/proxy-$TAG" >"$OUT/port" </dev/null &
PROXY=$!
for _ in $(seq 100); do [ -s "$OUT/port" ] && break; sleep 0.05; done
URL=http://127.0.0.1:$(cat "$OUT/port")

T0=$(date +%s)
(cd "$WD" && exec env "${ENV[@]}" XDG_STATE_HOME=$OUT/state AWL_URL=$URL "$BIN" ${CONT:+-c} -p "$PROMPT" \
  >"$OUT/answer-$TAG.md" 2>"$OUT/log-$TAG.txt" </dev/null) &
AWL=$!
(
  while kill -0 $AWL 2>/dev/null; do
    now=$(date +%s)
    last=$(stat -c %Y "$OUT"/proxy-$TAG/*.jsonl "$OUT"/proxy-$TAG/*.active 2>/dev/null | sort -n | tail -1)
    why=""
    [ $((now - T0)) -gt ${QA_TIMEOUT:-1800} ] && why="TIMEOUT after ${QA_TIMEOUT:-1800} s"
    [ -z "$last" ] && [ $((now - T0)) -gt 180 ] && why="STALLED: no request in 180 s"
    [ -n "$last" ] && [ $((now - last)) -gt 300 ] && why="STALLED: no request for 300 s"
    if [ -n "$why" ]; then
      echo "qa: $NAME $why, stopping awl" | tee -a "$OUT/summary.txt" >&2
      kill -INT $AWL 2>/dev/null; sleep 5; kill -KILL $AWL 2>/dev/null
      break
    fi
    sleep 5
  done
) &
GUARD=$!
set +e
wait $AWL
RC=$?
set -e
kill $GUARD $PROXY 2>/dev/null || true
wait $PROXY 2>/dev/null || true
SECS=$(($(date +%s) - T0))

git -C "$WD" add -N . 2>/dev/null || true
BASE=$(cat "$OUT/base")
git -C "$WD" diff "$BASE" >"$OUT/diff-$TAG.patch"
CHECKS=""
for c in "zig build test" "zig build e2e" "zig build -Doptimize=ReleaseSmall" "bash tests/check.sh"; do
  if (cd "$WD" && timeout 900 $c >"$OUT/check-$(echo $c | tr ' /' '__').txt" 2>&1 </dev/null); then
    CHECKS="$CHECKS ok:${c##* }"
  else
    CHECKS="$CHECKS FAIL:${c##* }"
  fi
done
cat "$OUT"/proxy-$TAG/*.jsonl 2>/dev/null | python3 -c "
import sys, json
rs = [json.loads(l) for l in sys.stdin]
print(f'$NAME/$TAG exit $RC  {$SECS} s  {len(rs)} requests  '
      f'{sum(r.get(\"prompt_tokens\", 0) for r in rs)} prompt  {sum(r.get(\"completion_tokens\", 0) for r in rs)} completion  '
      f'files: $(git -C "$WD" diff --stat "$BASE" | tail -1 | tr -d '\n' | sed 's/^ *//')  checks:$CHECKS')" | tee -a "$OUT/summary.txt"
