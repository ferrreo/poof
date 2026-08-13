FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System packages needed to fetch the toolchain and build native Zig code.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        xz-utils \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install a pinned, checksum-verified Zig toolchain.
ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN curl -fsSL -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && mkdir -p /usr/local/zig \
    && tar -xf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1 \
    && ln -sf /usr/local/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz \
    && zig version

USER ubuntu
