# The Linux test rig for a Mac (docs/dev-on-mac.md). Built and run by rig/run.sh:
# Ubuntu 24.04 like CI's runners, for linux/arm64 (native on Apple Silicon) or
# linux/amd64 (emulated, --amd64).
# The base is named by arch (arm64v8/ubuntu or amd64/ubuntu) because the legacy docker
# builder (no buildx) ignores --platform once the other arch's ubuntu:24.04 is pulled.
ARG BASE=arm64v8/ubuntu:24.04
FROM $BASE
ENV DEBIAN_FRONTEND=noninteractive
# What the suites call: bwrap (the sandbox), rg and fd (awl's tools), hyperfine and file
# (tests/check.sh), openssl (the https e2e check), python3 + pyte (fake server, tests/tui.py),
# curl, ip, unshare, busctl (systemd) and git (probes in tests/sandbox.sh).
RUN apt-get update -q && apt-get install -yq --no-install-recommends \
    bubblewrap ripgrep fd-find hyperfine python3 python3-pyte curl ca-certificates iproute2 \
    util-linux dbus systemd git openssl file procps xz-utils \
    && ln -sf /usr/bin/fdfind /usr/bin/fd && rm -rf /var/lib/apt/lists/*
# Zig 0.16.0, checked against the sha256 pins in scripts/release.sh. The arch is dpkg's:
# the legacy docker builder sets no TARGETARCH. Zig works on arm64; under amd64 emulation
# it segfaults, which is why rig/run.sh cross-compiles on the Mac.
RUN arch=$(dpkg --print-architecture) && case "$arch" in \
      arm64) host=aarch64-linux sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;; \
      amd64) host=x86_64-linux sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;; \
      *) echo "no pinned Zig for $arch" >&2; exit 2 ;; \
    esac \
    && curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-$host-0.16.0.tar.xz" \
    && echo "$sum  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz && ln -s /opt/zig/zig /usr/local/bin/zig
# The sandbox tests need a non-root user with a real home, and its /run/user/<uid>:
# tests/sandbox.sh puts a stand-in bus socket there to prove the sandbox hides it.
RUN useradd -m -s /bin/bash tester && install -d -o tester -g tester -m 700 "/run/user/$(id -u tester)"
USER tester
ENV HOME=/home/tester
WORKDIR /work
