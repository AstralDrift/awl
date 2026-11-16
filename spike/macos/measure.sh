#!/bin/sh
# Build the two spike programs for the host Mac and print size, startup and peak RSS.
# Usage (from the repository root): sh spike/macos/measure.sh
set -eu
cd "$(dirname "$0")"
OUT=${TMPDIR:-/tmp}/awl-spike.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
for p in control shape sbinit scrub; do
  mise exec -- zig build-exe "$p.zig" -target "$(uname -m | sed 's/arm64/aarch64/')-macos" -OReleaseSmall -fstrip -fsingle-threaded -lc \
    -femit-bin="$OUT/$p" --cache-dir "$OUT/cache" >/dev/null
  [ $p = sbinit ] || [ $p = scrub ] || echo "$p: $(stat -f %z "$OUT/$p") bytes; links: $(otool -L "$OUT/$p" 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' ')"
done
"$OUT/shape"
# peak RSS of each as a child (ru_maxrss is bytes on macOS); /usr/bin/time -l needs a sysctl that
# some sandboxes refuse, so ask the kernel through python instead
python3 - "$OUT" <<'PY'
import os, resource, subprocess, sys
for argv in (["control"], ["shape", "--version"], ["shape"], ["/usr/bin/true"]):
    pid = os.fork()
    if pid == 0:
        os.dup2(os.open("/dev/null", os.O_WRONLY), 1)
        os.execv(os.path.join(sys.argv[1], argv[0]), argv)
    _, _, ru = os.wait4(pid, 0)
    print("%s: peak RSS %d KB" % (" ".join(argv), ru.ru_maxrss // 1024))
PY
if command -v hyperfine >/dev/null; then
  hyperfine -N -w 20 -r 300 "$OUT/control" "$OUT/shape --version" "$OUT/shape" /usr/bin/true 2>/dev/null | grep -E 'Benchmark|Time'
else
  echo "no hyperfine: startup not measured"
fi

# awl's own secret in its environment block (spike/macos/scrub.zig)
AWL_KEY=hunter6-probe "$OUT/scrub"

# What the sandbox costs per command (spike/macos/sbinit.zig). Needs a shell that is not itself
# inside a Seatbelt sandbox.
if /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  W=$(mktemp -d "$(cd ../.. && pwd -P)/.zig-cache/sbinit.XXXXXX")
  mkdir -p "$W/proj"
  T=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
  C=$(cd "$(getconf DARWIN_USER_CACHE_DIR)" && pwd -P)
  # awl would write the profile with the paths in it; here sed puts them in place of (param ...)
  sed -e "s|(param \"ROOT\")|\"$W/proj\"|g" -e "s|(param \"HOME\")|\"$HOME\"|g" -e "s|(param \"TMP\")|\"$T\"|g" \
    -e "s|(param \"CACHE\")|\"$C\"|g" -e "s|(param \"SESSIONS\")|\"$W/sessions\"|g" -e "s|(param \"VIEW\")|\"$W/sessions/view\"|g" \
    -e "s|(param \"NET\")|\"off\"|g" -e "s|(param \"LOCAL\")|\"off\"|g" -e "s|(param \"PORT\")|\"1\"|g" awl.sb >"$W/awl.sb"
  "$OUT/sbinit" "$W/awl.sb" 300 "$W/outside" "$W/proj/inside" \
    "/bin/sleep 300 & echo \$! >$W/proj/jobpid" "kill \$(cat $W/proj/jobpid)"
  rm -rf "$W"
else
  echo "sandbox cost not measured: this shell is inside a Seatbelt sandbox (run from a plain terminal)"
fi
