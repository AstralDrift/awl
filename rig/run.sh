#!/bin/bash
# The Linux test rig for a Mac: cross-compile here, run the suites in a Linux container.
#   rig/run.sh [unit|check|e2e|sandbox|all|shell]... [--amd64]
# Default is all. aarch64 runs natively on Apple Silicon; --amd64 is emulated x86_64, and
# its numbers are labelled so. `shell` opens the container in the current directory with
# awl on PATH. See docs/dev-on-mac.md.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SYSCTL=kernel.apparmor_restrict_unprivileged_userns

arch=arm64 base=arm64v8 target=aarch64-linux out=zig-out/arm label="aarch64 native"
suites=()
for a in "$@"; do
  case $a in
  --amd64) arch=amd64 base=amd64 target=x86_64-linux out=zig-out/amd64 label="emulated" ;;
  unit | check | e2e | sandbox | shell) suites+=("$a") ;;
  all) suites+=(unit check e2e sandbox) ;;
  *)
    sed -n '2,6s/^# \{0,1\}//p' "$0" >&2
    exit 2
    ;;
  esac
done
[ ${#suites[@]} -gt 0 ] || suites=(unit check e2e sandbox)
die() {
  echo "rig: $*" >&2
  exit 1
}
wants() { case " ${suites[*]} " in *" $1 "*) return 0 ;; *) return 1 ;; esac }

# --- cross-compile on the Mac (Zig segfaults under emulation, so never in the container)
caller=$PWD
cd "$ROOT" || exit 1 # mise finds its zig from the repo's mise.toml
zig=${ZIG:-$(command -v zig || mise which zig 2>/dev/null)}
[ -x "$zig" ] || die "no zig: mise install, or set ZIG"
[ "$("$zig" version)" = 0.16.0 ] || die "$zig is $("$zig" version), want 0.16.0"
echo "rig: building $target into $out"
"$zig" build -Doptimize=ReleaseSmall -Dtarget="$target" -Dcpu=baseline -p "$out" || die "zig build failed"
if wants unit; then
  "$zig" test src/main.zig -target "$target" --test-no-exec -femit-bin="$out/awl-test" || die "zig test build failed"
fi

# --- the image, tagged by the Dockerfile's hash so an edit rebuilds it
docker version >/dev/null 2>&1 || die "docker is not reachable (colima start?)"
image=awl-rig:$(shasum -a 256 rig/Dockerfile | cut -c1-12)-$arch
if ! docker image inspect "$image" >/dev/null 2>&1; then
  echo "rig: building image $image"
  docker build --platform "linux/$arch" --build-arg "BASE=$base/ubuntu:24.04" -t "$image" rig || die "image build failed"
  got=$(docker image inspect "$image" --format '{{.Architecture}}')
  [ "$got" = "$arch" ] || {
    docker rmi "$image" >/dev/null
    die "the image came out $got, not $arch"
  }
fi
# --ulimit core=0: a crash under emulation would leave a qemu core file in the repo.
run=(docker run --rm --privileged --ulimit core=0 --platform "linux/$arch" --add-host awl-e2e.test:127.0.0.1)

# --- bubblewrap needs unprivileged user namespaces in the VM's kernel (the container shares it)
restrict=$("${run[@]}" "$image" sh -c "cat /proc/sys/${SYSCTL//.//} 2>/dev/null || echo 0")
[ -n "$restrict" ] || die "the container did not start (see docker's error above)"
if [ "$restrict" != 0 ]; then
  cat >&2 <<EOF
rig: the Docker VM has $SYSCTL=$restrict, so bubblewrap cannot
rig: start and awl's sandbox fails for the rig's reason, not awl's. It resets when the VM
rig: restarts. Run this, then rig/run.sh again:

    colima ssh -- sudo sysctl -w $SYSCTL=0

EOF
  exit 1
fi

if wants shell; then
  [ "${suites[*]}" = shell ] || die "shell runs alone"
  env=()
  while IFS= read -r v; do env+=(-e "$v"); done < <(compgen -e | grep '^AWL_')
  [ -t 0 ] && tty=-it || tty=-i # piped commands work too: echo 'awl --version' | rig/run.sh shell
  exec "${run[@]}" "$tty" ${env[@]+"${env[@]}"} -v "$ROOT/$out/bin:/opt/awl:ro" -e PATH=/opt/awl:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    -v "$caller:/work" -w /work "$image" bash
fi

# --- the suites, as tester, each with its log under .zig-cache/rig/
logs=.zig-cache/rig/$arch
mkdir -p "$logs"
summary=() failed=0 limit=${RIG_TIMEOUT:-1200} # seconds per suite
# An interrupted run must not leave its container behind (under emulation one ran for days).
running=
trap '[ -z "$running" ] || docker kill "$running" >/dev/null 2>&1' EXIT
trap 'exit 130' INT TERM
# suite <name> <command>: run it, keep the log, fail on a non-zero exit or any skipped check.
suite() {
  local name=$1 rc note dog cname=awl-rig-$1-$$
  shift
  echo "== $name ($label)"
  # The time limit is kept from the Mac: under emulation a hung test (the pidfd unit test)
  # takes an in-container `timeout` down with it, and the container would run for days.
  rm -f "$logs/$name.timeout"
  (sleep "$limit" && touch "$logs/$name.timeout" && docker kill "$cname") >/dev/null 2>&1 &
  dog=$! running=$cname
  # CI=true: the test scripts then fail on a check they would otherwise skip.
  # In the background, then wait: bash runs a trap only between foreground commands.
  {
    "${run[@]}" --name "$cname" -e CI=true -v "$ROOT:/work" "$image" "$@" 2>&1
    echo $? >"$logs/$name.rc"
  } | sed -E "/^(ok +startup|ok +peak RSS| +size| +idle RSS)/s/\$/ [$label]/" | tee "$logs/$name.log" &
  wait $!
  rc=$(cat "$logs/$name.rc")
  pkill -P "$dog" 2>/dev/null
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  running=
  if [ -e "$logs/$name.timeout" ]; then
    summary+=("FAIL  $name: timed out after $limit s, killed")
    failed=1
    return
  fi
  note=$(grep -E "^($name: |test_proxy: |CHECK |All [0-9]+ tests passed|[0-9]+ passed)" "$logs/$name.log" | tail -1)
  note=${note#"$name: "}
  if grep -q '^skip' "$logs/$name.log"; then
    rc=1 note="$note (a check was skipped: $(grep -m1 '^skip' "$logs/$name.log"))"
  fi
  if [ "$rc" = 0 ]; then summary+=("PASS  $name: $note"); else
    summary+=("FAIL  $name: exit $rc, $note")
    failed=1
  fi
}
B=$out/bin/awl
wants unit && suite unit "$out/awl-test"
wants check && suite check sh tests/check.sh "$B"
wants e2e && {
  suite e2e bash tests/e2e.sh "$B"
  suite embed bash tests/embed.sh "$B"
  suite proxy python3 arena/test_proxy.py "/work/$B"
}
wants sandbox && {
  suite sandbox bash tests/sandbox.sh "$B"
  suite nosandbox bash tests/nosandbox.sh "$B"
}

echo "== summary ($label, $(git rev-parse --short HEAD 2>/dev/null))"
printf '%s\n' "${summary[@]}"
[ "$arch" = arm64 ] || echo "emulated x86_64: timings and RSS are not awl's, and checks can flake; CI gives the x86_64 verdict"
exit $failed
