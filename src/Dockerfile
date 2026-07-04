# Dockerfile — legacy atomicdex multi-stage build
#
# One file. All targets. No host dependencies between stages.
#
#   docker build --target kdf     -o output/linux .    # KDF only
#   docker build --target desktop -o output/linux .    # Desktop AppImage
#   docker build --target all     -o output/linux .    # Everything
#
# Build args:
#   PLATFORM=linux|mac|windows   (default: linux)
#
# Layer strategy (top = stable, bottom = volatile):
#   Each stage's first layers (apt, clone, fetch) cache permanently.
#   Only the final COPY + RUN rebuilds on project file changes.
#   Cache mounts preserve build artifacts for incremental compilation.

ARG PLATFORM=linux

# ═══════════════════════════════════════════════════════════════
# Stage: deps-kdf — system deps + KDF source + crate fetch
# ═══════════════════════════════════════════════════════════════
FROM rust:1.84.0-bookworm AS deps-kdf

ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
RUN apt-get update && apt-get install -y \
    git curl wget jq \
    build-essential cmake pkg-config libssl-dev clang \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/* \
    && git config --global advice.detachedHead false

# Clone KDF source — only rebuilds when sources.json changes
COPY config/sources.json /tmp/cfg/
RUN KDF_REPO=$(jq -r '.kdf.repo' /tmp/cfg/sources.json) && \
    KDF_COMMIT=$(jq -r '.kdf.commit' /tmp/cfg/sources.json) && \
    git clone "$KDF_REPO" /tmp/kdf-src && \
    cd /tmp/kdf-src && \
    git checkout "$KDF_COMMIT" && \
    git submodule update --init --recursive

# Fetch crates — only rebuilds when upstream Cargo.toml changes
RUN rustup target add x86_64-unknown-linux-gnu && \
    cd /tmp/kdf-src && \
    cargo fetch --target x86_64-unknown-linux-gnu

# ═══════════════════════════════════════════════════════════════
# Stage: kdf — build KDF binary
# ═══════════════════════════════════════════════════════════════
FROM deps-kdf AS kdf
ARG PLATFORM=linux
ENV PLATFORM=${PLATFORM}
# Tiered COPY: config (rarely changes) → scripts (occasionally changes)
# Editing README no longer invalidates the build cache
COPY config/ /builder/config/
COPY src/docker-build.sh src/_build-lib.sh /builder/src/
WORKDIR /builder
RUN --mount=type=cache,target=/builder/.build/kdf/target \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    mkdir -p .build/kdf "output/${PLATFORM}" && \
    [ -d .build/kdf/.git ] || cp -a /tmp/kdf-src/. .build/kdf/ && \
    ./src/docker-build.sh kdf

# ═══════════════════════════════════════════════════════════════
# Stage: deps-desktop — Qt5 + desktop source + libwally + vcpkg
# ═══════════════════════════════════════════════════════════════
FROM ubuntu:22.04 AS deps-desktop
ARG PLATFORM=linux

ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
RUN apt-get update && apt-get install -y \
    git curl wget jq \
    build-essential cmake pkg-config libssl-dev protobuf-compiler \
    qtbase5-dev qtdeclarative5-dev qtquickcontrols2-5-dev \
    qttools5-dev qtwebengine5-dev libqt5svg5-dev libqt5charts5-dev \
    libqt5waylandclient5-dev libcpprest-dev \
    qml-module-qtquick-controls qml-module-qtquick-controls2 \
    qml-module-qtquick-dialogs qml-module-qtquick-extras \
    qml-module-qtquick-layouts qml-module-qtquick-shapes \
    qml-module-qtcharts qml-module-qtgraphicaleffects \
    qml-module-qtwebengine \
    qml-module-qt-labs-platform qml-module-qt-labs-folderlistmodel \
    qml-module-qt-labs-settings \
    libxcb1-dev libxcb-keysyms1-dev libxcb-render-util0-dev \
    libxkbcommon-x11-0 libgl1-mesa-dev libfuse2 \
    autoconf automake libtool ninja-build fuse \
    libxcb-icccm4 libxcb-image0 libxcb-xinerama0 \
    libxcursor-dev libxcomposite-dev libxdamage-dev \
    libxrandr-dev libxtst-dev libxss-dev libdbus-1-dev \
    libevent-dev libfontconfig1-dev libudev-dev libpci-dev \
    libnss3-dev libasound2-dev libegl1-mesa-dev libcap-dev \
    libpulse-dev linux-libc-dev lsb-release nodejs \
    libsodium-dev m4 gettext \
    software-properties-common unzip zip zstd \
    python3 python-is-python3 \
    patchelf \
    desktop-file-utils \
    && rm -rf /var/lib/apt/lists/* \
    && git config --global advice.detachedHead false

# Clone desktop source — only rebuilds when sources.json changes
COPY config/sources.json /tmp/cfg/
RUN DESKTOP_REPO=$(jq -r '.desktop.repo' /tmp/cfg/sources.json) && \
    DESKTOP_COMMIT=$(jq -r '.desktop.commit' /tmp/cfg/sources.json) && \
    git clone "$DESKTOP_REPO" /tmp/desktop-src && \
    cd /tmp/desktop-src && \
    git checkout "$DESKTOP_COMMIT" && \
    git submodule update --init --recursive

# Build libwally — only rebuilds when Dockerfile changes
RUN git clone --depth 1 https://github.com/ElementsProject/libwally-core \
        --recurse-submodules -b release_0.9.2 /tmp/libwally-core && \
    cd /tmp/libwally-core && \
    ./tools/autogen.sh && \
    PYTHON=python3 ./configure --disable-shared --disable-tests && \
    make -j$(nproc) install && \
    rm -rf /tmp/libwally-core

# vcpkg bootstrap + install — only rebuilds when vcpkg.json changes
RUN cd /tmp/desktop-src && \
    sed -i '/"cpprestsdk"/d' vcpkg.json 2>/dev/null || true && \
    sed -i '/"boost-/d' vcpkg.json 2>/dev/null || true && \
    sed -i '/"libsodium"/d' vcpkg.json 2>/dev/null || true && \
    cd ci_tools_atomic_dex/vcpkg-repo && \
    ./bootstrap-vcpkg.sh && \
    ./vcpkg install --triplet x64-linux

# cmake upgrade — only rebuilds when version check triggers
RUN CMAKE_VER=$(cmake --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' || echo "0.0") && \
    if [ "$(printf '%s\n' "4.3" "$CMAKE_VER" | sort -V | head -1)" != "4.3" ]; then \
        echo "upgrading cmake ${CMAKE_VER} → 4.3.3" && \
        curl -sL https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-linux-x86_64.tar.gz | \
        tar xz --strip-components=1 -C /usr/local; \
    else \
        echo "cmake ${CMAKE_VER} OK"; \
    fi

# icudtl.dat stub — Ubuntu 22.04 Qt5 bundles ICU in the .so, not as a separate file.
# linuxdeployqt still looks for it. Missing file = QtWebEngine crash at runtime.
RUN if [ ! -f /usr/share/qt5/resources/icudtl.dat ]; then \
        touch /usr/share/qt5/resources/icudtl.dat && \
        echo "icudtl.dat stub created"; \
    fi

# QtWebEngineProcess RPATH fix — linuxdeployqt copies this binary into the AppDir
# but does NOT set RPATH. On hosts without system Qt5 (Debian 13+, etc.), the
# dynamic linker can't find libQt5Core.so.5 even though it's bundled right next
# to the binary at usr/lib/. Setting RPATH=$ORIGIN/../lib makes the binary find
# its own bundled libs regardless of the host's LD_LIBRARY_PATH.
RUN QTWEP=$(find /usr -name QtWebEngineProcess -type f -not -path '*/qt6/*' 2>/dev/null | head -1) && \
    if [ -n "$QTWEP" ] && [ -f "$QTWEP" ]; then \
        echo "Patching RPATH on $QTWEP" && \
        patchelf --set-rpath '$ORIGIN/../lib' "$QTWEP" && \
        patchelf --print-rpath "$QTWEP"; \
    else \
        echo "WARNING: QtWebEngineProcess not found — RPATH not patched"; \
    fi

# ═══════════════════════════════════════════════════════════════
# Stage: desktop — build desktop AppImage
# ═══════════════════════════════════════════════════════════════
FROM deps-desktop AS desktop
ARG PLATFORM=linux
ENV PLATFORM=${PLATFORM}

# Tiered COPY: config (rarely changes) → scripts (occasionally changes)
# Editing README no longer invalidates the build cache
COPY config/ /builder/config/
COPY src/docker-build.sh src/_build-lib.sh /builder/src/

# KDF binary from kdf stage — overwrites any stale host copy
COPY --from=kdf /builder/output/linux/kdf /builder/output/linux/kdf

WORKDIR /builder
RUN --mount=type=cache,target=/builder/.build/desktop/ci_tools_atomic_dex/build-Release \
    --mount=type=cache,target=/builder/.build/desktop/ci_tools_atomic_dex/vcpkg-repo/vcpkg_installed \
    mkdir -p .build/desktop "output/${PLATFORM}" && \
    [ -d .build/desktop/.git ] || cp -a /tmp/desktop-src/. .build/desktop/ && \
    ./src/docker-build.sh desktop

# ═══════════════════════════════════════════════════════════════
# Stage: all — combined export
# ═══════════════════════════════════════════════════════════════
FROM scratch AS all
ARG PLATFORM=linux
COPY --from=kdf /builder/output/linux/kdf /kdf
COPY --from=kdf /builder/output/linux/kdf.sha256 /kdf.sha256
COPY --from=desktop /builder/output/linux/komodo-wallet-desktop-x86_64.AppImage /komodo-wallet-desktop-x86_64.AppImage
COPY --from=desktop /builder/output/linux/komodo-wallet-desktop.sha256 /komodo-wallet-desktop.sha256
