#!/bin/sh
# Build a release the way the Release workflow does, so anyone can compare checksums:
#   git checkout v0.1.0 && scripts/release.sh
# Fetches Zig 0.16.0 from ziglang.org (checked against its published sha256) unless
# $ZIG already is that version, runs `zig build release`, and writes SHA256SUMS.
# Output: zig-out/release/{awl-linux-x86_64,awl-linux-aarch64,SHA256SUMS}
set -eu
cd "$(dirname "$0")/.."
version=0.16.0
# https://ziglang.org/download/index.json, "0.16.0" -> "<host>" -> "shasum"
case "$(uname -s)-$(uname -m)" in
Linux-x86_64) host=x86_64-linux sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
Linux-aarch64 | Linux-arm64) host=aarch64-linux sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
Darwin-arm64) host=aarch64-macos sum=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
Darwin-x86_64) host=x86_64-macos sum=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
*) echo "release.sh: no pinned Zig for $(uname -s)-$(uname -m)" >&2 && exit 2 ;;
esac
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

zig=${ZIG:-}
if [ -z "$zig" ] || [ "$("$zig" version 2>/dev/null)" != "$version" ]; then
  dir=${XDG_CACHE_HOME:-$HOME/.cache}/awl-release/zig-$host-$version
  if [ ! -x "$dir/zig" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    echo "release.sh: fetching Zig $version for $host" >&2
    curl -fsSL -o "$tmp/zig.tar.xz" "https://ziglang.org/download/$version/zig-$host-$version.tar.xz"
    (cd "$tmp" && echo "$sum  zig.tar.xz" | sha256 -c - >&2)
    tar -xJf "$tmp/zig.tar.xz" -C "$tmp"
    mkdir -p "$(dirname "$dir")"
    rm -rf "$dir"
    mv "$tmp/zig-$host-$version" "$dir"
  fi
  zig=$dir/zig
fi

[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] ||
  echo "release.sh: warning: uncommitted changes; these bytes will not match the release" >&2

"$zig" build release
cd zig-out/release
sha256 awl-linux-x86_64 awl-linux-aarch64 >SHA256SUMS
cat SHA256SUMS
