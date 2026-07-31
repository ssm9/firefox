# Firefox build environment for the fork build server.
#
# Deliberately does NOT contain the source tree or the toolchains: both live on
# persistent volumes so that a rebuilt image does not throw away a warm sccache
# or force a fresh 5+ GB clone. The image is just the system layer.

FROM debian:bookworm

# CARGO_HOME and RUSTUP_HOME point at the state volume because mach bootstrap
# installs Rust with rustup, which otherwise writes to $HOME/.cargo -- inside
# the container, and therefore lost whenever the container is recreated.
ENV DEBIAN_FRONTEND=noninteractive \
    SHELL=/bin/bash \
    MOZBUILD_STATE_PATH=/state/mozbuild \
    SCCACHE_DIR=/state/sccache \
    SCCACHE_CACHE_SIZE=40G \
    CARGO_HOME=/state/cargo \
    RUSTUP_HOME=/state/rustup \
    PATH=/state/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# `mach bootstrap` installs most build dependencies itself, but it needs a
# working python/git/curl to get that far. libnss3-tools provides certutil,
# used by gen_mar_key.sh. zstd and xz are needed to unpack toolchain artifacts.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        build-essential \
        pkg-config \
        libssl-dev \
        libnss3-tools \
        zip \
        unzip \
        msitools \
        libc6-i386 \
        lib32gcc-s1 \
        lib32stdc++6 \
        lib32z1 \
        xz-utils \
        bzip2 \
        zstd \
        tar \
        rsync \
        m4 \
        procps \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# sccache is what keeps release-to-release rebuilds tolerable on one machine.
ARG SCCACHE_VERSION=0.8.2
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) sc_arch=x86_64 ;; \
         arm64) sc_arch=aarch64 ;; \
         *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/sccache.tar.gz \
        "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-${sc_arch}-unknown-linux-musl.tar.gz" \
    && tar -xzf /tmp/sccache.tar.gz -C /tmp \
    && install -m 0755 "/tmp/sccache-v${SCCACHE_VERSION}-${sc_arch}-unknown-linux-musl/sccache" /usr/local/bin/sccache \
    && rm -rf /tmp/sccache*

COPY build-loop.sh /usr/local/bin/build-loop.sh
RUN chmod +x /usr/local/bin/build-loop.sh

# /state  - mozbuild toolchains, sccache, NSS signing db, last-built marker
# /src    - the git checkout
# /obj    - object directories
# /www    - published manifests and downloads, shared read-only with nginx
# /vs     - packaged MSVC toolchain for cross-compiling Windows
VOLUME ["/state", "/src", "/obj", "/www", "/vs"]

ENTRYPOINT ["/usr/local/bin/build-loop.sh"]
