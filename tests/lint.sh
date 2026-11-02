#!/bin/sh
# Lint gate: zig fmt, project rules, Zig version pins, arena/LOG.md promises, commit figures,
# then the shell, Python and workflow linters.
# Usage: tests/lint.sh [path/to/zig]   (zig build lint passes the running zig)
# Lint tools come from mise.toml. A missing one is skipped locally and fails under CI=true.
set -eu
cd "$(dirname "$0")/.."
ZIG=${1:-zig}
rc=0
fail() { echo "LINT FAIL: $*"; rc=1; }
ok() { echo "ok  $*"; }
have() {
  command -v "$1" >/dev/null && return 0
  [ "${CI:-}" = true ] && fail "$1 not installed (mise.toml pins it)" || echo "skip $1 (not installed; mise install)"
  return 1
}

if "$ZIG" fmt --check src build.zig build.zig.zon; then ok "zig fmt"; else fail "zig fmt: run \`zig fmt src build.zig\`"; fi

# `return f() == {}` reads as "return after f" but returns true; in tui.command true
# means quit (it made /resume quit awl). Write the call, then `return false`.
if grep -n '== {}' src/*.zig; then fail "'== {}' in src (see tests/lint.sh)"; else ok "no '== {}'"; fi

# A file's tests run only if main.zig's test block imports it (agent.zig's never ran).
t=0
for f in src/*.zig; do
  n=$(basename "$f")
  if grep -q '^test "' "$f" && ! grep -q "_ = @import(\"$n\");" src/main.zig; then
    fail "$n has tests but main.zig's test block does not import it"
    t=1
  fi
done
[ $t = 1 ] || ok "every file with tests is in the test build"

# The Zig version is written in four places; Dependabot updates none of them.
want=$(sed -n 's/^zig = "\(.*\)"$/\1/p' mise.toml)
v=0
for got in \
  "$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",$/\1/p' build.zig.zon)" \
  "$(sed -n 's/^version=\(.*\)$/\1/p' scripts/release.sh)" \
  "$(sed -n 's/.*zig-\$arch-linux-\([0-9.]*\)\/zig.*/\1/p' .github/workflows/release.yml)"; do
  [ "$got" = "$want" ] || { fail "Zig version: mise.toml says $want, found '$got' (build.zig.zon, scripts/release.sh, release.yml)"; v=1; }
done
[ $v = 1 ] || ok "Zig $want everywhere"

# arena/LOG.md: a decision that says "next: X" is a promise (the row is a Keep on condition that X
# gets measured). Four October promises were never followed up. After 14 days the row fails lint:
# edit its decision cell to say what happened (done: the row that measured it; dropped: why).
if python3 - <<'PY'
import datetime, re, sys
today = datetime.date.today()
stale = []
for n, line in enumerate(open("arena/LOG.md"), 1):
    if not line.startswith("| 20"):
        continue
    cells = line.strip().strip("|").split("|")
    try:
        day = datetime.date.fromisoformat(cells[0].strip()[:10])
    except ValueError:
        continue
    if re.search(r"\bnext:", cells[-1], re.I) and (today - day).days > 14:
        stale.append("  line %d (%s, %d days): %s" % (n, day, (today - day).days, cells[-1].strip()[:100]))
if stale:
    print("arena/LOG.md promises older than 14 days (edit the decision cell: what happened?):\n" + "\n".join(stale))
sys.exit(1 if stale else 0)
PY
then ok "no arena/LOG.md promise older than 14 days"; else fail "stale promise in arena/LOG.md"; fi

# A commit that touches src/ or build.zig says what it cost (AGENTS.md): a size, RSS or startup
# figure. Checked on the commits this branch adds over main; skipped when no main ref is known
# (a shallow clone: CI's lint job fetches the whole history for this).
base=$(git rev-parse --verify -q origin/main || git rev-parse --verify -q main || true)
if [ -z "$base" ]; then
  echo "skip commit figures (no main ref)"
else
  c=0
  for sha in $(git rev-list --no-merges "$base..HEAD" -- src build.zig); do
    if ! git log -1 --format=%B "$sha" | grep -qE '[0-9][0-9,.]* ?(B|KB|MB|ms)\b|RSS|startup'; then
      fail "commit $(git log -1 --format='%h %s' "$sha") touches src/ or build.zig but names no size, RSS or startup figure"
      c=1
    fi
  done
  [ $c = 1 ] || ok "every src commit over main carries a measured figure"
fi

# arena/tasks and arena/qa hold task fixtures with planted bugs; they are not linted.
sh_files=$(git ls-files '*.sh' ':!arena/tasks' ':!arena/qa')
py_files=$(git ls-files '*.py' ':!arena/tasks')
[ -n "$sh_files" ] && [ -n "$py_files" ] || { fail "git ls-files found no scripts"; exit 1; }
if have shellcheck; then
  # shellcheck disable=SC2086
  if shellcheck -S warning $sh_files; then ok shellcheck; else fail shellcheck; fi
fi
if have ruff; then
  # Pyflakes and syntax errors only: unused names, undefined names, bad imports.
  # shellcheck disable=SC2086
  if ruff check --no-cache --quiet --select F,E9 $py_files; then ok ruff; else fail ruff; fi
fi
if have actionlint; then
  if actionlint; then ok actionlint; else fail actionlint; fi
fi

[ $rc = 0 ] && echo "LINT PASS"
exit $rc
