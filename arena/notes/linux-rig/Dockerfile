FROM --platform=linux/amd64 debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -yq --no-install-recommends \
    bash python3 bubblewrap ripgrep fd-find hyperfine git build-essential curl ca-certificates file procps jq xz-utils \
    && ln -sf /usr/bin/fdfind /usr/bin/fd && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz \
    && ln -s /opt/zig/zig /usr/local/bin/zig
RUN useradd -m -u 501 -s /bin/bash m
USER m
WORKDIR /work
