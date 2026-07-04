#!/bin/bash
# _build-lib.sh — Shared build primitives
# Sourced by docker-build.sh and build-linux.sh.
# No side effects. No main(). Pure function library.
#
# Callers must define these before sourcing:
#   CONFIG_DIR, SOURCES_JSON, BUILD_DIR, BUILD_CPUS
#
# Callers may define these color helpers; library provides fallbacks:
#   step(), ok(), warn(), fail(), info()

# ── Fallback color helpers (caller can override) ─────────────
if ! declare -f step &>/dev/null; then
    step()  { echo "→ $1"; }
fi
if ! declare -f ok &>/dev/null; then
    ok()    { echo "  ✓ $1"; }
fi
if ! declare -f warn &>/dev/null; then
    warn()  { echo "  ⚠ $1"; }
fi
if ! declare -f fail &>/dev/null; then
    fail()  { echo "  ✗ $1"; }
fi
if ! declare -f info &>/dev/null; then
    info()  { echo "    $1"; }
fi

# ═══════════════════════════════════════════════════════════════
# Config readers
# ═══════════════════════════════════════════════════════════════

read_sources() {
    KDF_REPO="${KDF_REPO:-$(jq -r '.kdf.repo' "$SOURCES_JSON")}"
    KDF_COMMIT="${KDF_COMMIT:-$(jq -r '.kdf.commit' "$SOURCES_JSON")}"
    DESKTOP_REPO="${DESKTOP_REPO:-$(jq -r '.desktop.repo' "$SOURCES_JSON")}"
    DESKTOP_COMMIT="${DESKTOP_COMMIT:-$(jq -r '.desktop.commit' "$SOURCES_JSON")}"
}



# ═══════════════════════════════════════════════════════════════
# Clone source at pinned commit (skips if already there)
# ═══════════════════════════════════════════════════════════════

clone_source() {
    local name="$1" repo="$2" commit="$3"
    local dir="${BUILD_DIR}/${name}"

    if [ -d "$dir/.git" ]; then
        local current
        current=$(cd "$dir" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        if [ "$current" = "$commit" ]; then
            ok "${name} source at ${commit} (cached)"
            return 0
        fi
        step "updating ${name}: ${current} → ${commit}"
        (cd "$dir" && git fetch origin && git checkout "$commit" && git submodule update --init --recursive)
    else
        step "cloning ${name} @ ${commit}"
        rm -rf "$dir"
        git clone --filter=blob:none "$repo" "$dir"
        (cd "$dir" && git checkout "$commit" && git submodule update --init --recursive)
    fi
    ok "${name} ready"
}

# ═══════════════════════════════════════════════════════════════
# Apply patches to a source tree
# ═══════════════════════════════════════════════════════════════

apply_patches_to() {
    local patch_dir="$1" target_dir="$2"

    if [ ! -d "$patch_dir" ] || [ -z "$(ls -A "$patch_dir" 2>/dev/null)" ]; then
        return 0
    fi
    for patch in "$patch_dir"/*.diff "$patch_dir"/*.patch; do
        [ -f "$patch" ] || continue
        local name; name=$(basename "$patch")
        if patch -p1 --dry-run -d "$target_dir" < "$patch" 2>/dev/null; then
            patch -p1 -d "$target_dir" < "$patch" 2>/dev/null && ok "applied $name" || warn "$name may already be applied"
        else
            ok "$name already applied"
        fi
    done
}



# ═══════════════════════════════════════════════════════════════
# Build libwally from source (skips if already installed)
# ═══════════════════════════════════════════════════════════════

ensure_libwally() {
    if [ -f /usr/local/lib/libwallycore.a ]; then
        ok "libwally already installed"
        return 0
    fi
    step "building libwally"
    git clone --depth 1 https://github.com/ElementsProject/libwally-core \
        --recurse-submodules -b release_0.9.2 /tmp/libwally-core 2>/dev/null || true
    cd /tmp/libwally-core
    ./tools/autogen.sh
    PYTHON=python3 ./configure --disable-shared --disable-tests
    make -j"${BUILD_CPUS:-$(nproc)}" install
    rm -rf /tmp/libwally-core
    ok "libwally installed"
}

# ═══════════════════════════════════════════════════════════════
# Ensure cmake 4.3+
# ═══════════════════════════════════════════════════════════════

ensure_cmake() {
    local cmake_ver
    cmake_ver=$(cmake --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' || echo "0.0")
    if [ "$(printf '%s\n' "4.3" "$cmake_ver" | sort -V | head -1)" != "4.3" ]; then
        step "upgrading cmake ${cmake_ver} → 4.3.3"
        curl -sL https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-linux-x86_64.tar.gz | \
            tar xz --strip-components=1 -C /usr/local
        ok "cmake 4.3.3"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Bootstrap vcpkg (skips if already set up)
# ═══════════════════════════════════════════════════════════════

ensure_vcpkg() {
    local dtop_dir="$1"
    local vcpkg_dir="${dtop_dir}/ci_tools_atomic_dex/vcpkg-repo"

    if [ ! -d "$vcpkg_dir/vcpkg" ]; then
        step "bootstrapping vcpkg"
        cd "$dtop_dir"
        sed -i '/"cpprestsdk"/d' vcpkg.json 2>/dev/null || true
        sed -i '/"boost-/d' vcpkg.json 2>/dev/null || true
        sed -i '/"libsodium"/d' vcpkg.json 2>/dev/null || true
        cd ci_tools_atomic_dex/vcpkg-repo
        ./bootstrap-vcpkg.sh
    fi

    step "vcpkg install (cached)"
    cd "$vcpkg_dir"
    ./vcpkg install --triplet x64-linux 2>&1 | sed 's/^/  /'

    # libsodium stub if vcpkg failed to build it
    if [ ! -f "${vcpkg_dir}/installed/x64-linux/share/unofficial-sodium/unofficial-sodiumConfig.cmake" ]; then
        mkdir -p "${vcpkg_dir}/installed/x64-linux/share/unofficial-sodium"
        cat > "${vcpkg_dir}/installed/x64-linux/share/unofficial-sodium/unofficial-sodiumConfig.cmake" << 'SODIUMCFG'
find_library(SODIUM_LIBRARY sodium REQUIRED)
find_path(SODIUM_INCLUDE_DIR sodium.h REQUIRED)
add_library(unofficial-sodium::sodium STATIC IMPORTED)
set_target_properties(unofficial-sodium::sodium PROPERTIES
    IMPORTED_LOCATION "${SODIUM_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${SODIUM_INCLUDE_DIR}")
SODIUMCFG
        ok "libsodium stub created"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Extract linuxdeployqt AppImage (skips if ready)
# ═══════════════════════════════════════════════════════════════

ensure_linuxdeployqt() {
    local dtop_dir="$1"
    local ldt_dir="${dtop_dir}/ci_tools_atomic_dex/linux_misc"

    if [ -f "${ldt_dir}/linuxdeployqt-continuous-x86_64.AppImage" ] && \
       [ ! -f "${ldt_dir}/squashfs-root/AppRun" ]; then
        cd "$ldt_dir"
        chmod +x linuxdeployqt-continuous-x86_64.AppImage
        ./linuxdeployqt-continuous-x86_64.AppImage --appimage-extract 2>/dev/null || true
        mv linuxdeployqt-continuous-x86_64.AppImage linuxdeployqt-continuous-x86_64.AppImage.orig 2>/dev/null || true
        ln -sf squashfs-root/AppRun linuxdeployqt-continuous-x86_64.AppImage
        cd "$dtop_dir"
        ok "linuxdeployqt ready"
    elif [ ! -f "${ldt_dir}/linuxdeployqt-continuous-x86_64.AppImage" ]; then
        warn "linuxdeployqt not found — AppImage packaging may be incomplete"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Symlink nss libraries (Ubuntu 22.04+ layout fix)
# ═══════════════════════════════════════════════════════════════

fix_nss_symlinks() {
    if [ -d /usr/lib/x86_64-linux-gnu/nss ]; then
        for f in /usr/lib/x86_64-linux-gnu/nss/*; do
            ln -sf "$f" /usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
        done
    fi
}

# ═══════════════════════════════════════════════════════════════
# Patch QtWebEngineProcess RPATH so it finds bundled Qt5 libs
# linuxdeployqt copies this binary into the AppDir but does NOT
# set RPATH. On hosts without system Qt5, the dynamic linker
# can't find libQt5Core.so.5 even though it's bundled at usr/lib/.
# ═══════════════════════════════════════════════════════════════

fix_qtwebengine_rpath() {
    if ! command -v patchelf >/dev/null 2>&1; then
        warn "patchelf not found — QtWebEngineProcess RPATH not patched"
        warn "  Install: apt install patchelf"
        return 0  # non-fatal — AppImage may still work on Qt5 hosts
    fi
    local qtwep
    qtwep=$(find /usr -name QtWebEngineProcess -type f -not -path '*/qt6/*' 2>/dev/null | head -1)
    if [ -n "$qtwep" ] && [ -f "$qtwep" ]; then
        local current_rpath
        current_rpath=$(patchelf --print-rpath "$qtwep" 2>/dev/null || echo "(none)")
        if [ "$current_rpath" != '$ORIGIN/../lib' ]; then
            step "Patching QtWebEngineProcess RPATH: $qtwep"
            patchelf --set-rpath '$ORIGIN/../lib' "$qtwep"
            ok "QtWebEngineProcess RPATH set → \$ORIGIN/../lib"
        else
            ok "QtWebEngineProcess RPATH already correct"
        fi
    else
        warn "QtWebEngineProcess not found — RPATH not patched"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Strip KDF FetchContent from desktop CMakeLists.txt
# ═══════════════════════════════════════════════════════════════

strip_kdf_fetchcontent() {
    local dtop_dir="$1"
    sed -i '/FetchContent_Declare(kdf/,+1d' "${dtop_dir}/CMakeLists.txt" 2>/dev/null || true
    sed -i 's/FetchContent_MakeAvailable(kdf /FetchContent_MakeAvailable(/' "${dtop_dir}/CMakeLists.txt" 2>/dev/null || true
    sed -i '/configure_file(\${kdf_SOURCE_DIR}/d' "${dtop_dir}/CMakeLists.txt" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Stage KDF binary into desktop assets + AppDir
# ═══════════════════════════════════════════════════════════════

stage_kdf() {
    local dtop_dir="$1" kdf_binary="$2"

    if [ ! -f "$kdf_binary" ]; then
        fail "KDF not found at ${kdf_binary}"
        return 1
    fi
    mkdir -p "${dtop_dir}/assets/tools/kdf"
    cp "$kdf_binary" "${dtop_dir}/assets/tools/kdf/kdf_kwd"
    ok "KDF staged"
}

stage_kdf_appdir() {
    local dtop_dir="$1"
    local appdir_assets="bin/AntaraAtomicDexAppDir/usr/share/assets"
    if [ -d "$appdir_assets" ]; then
        mkdir -p "$appdir_assets/tools/kdf"
        cp "${dtop_dir}/assets/tools/kdf/kdf_kwd" "$appdir_assets/tools/kdf/kdf_kwd" 2>/dev/null || true
    fi
}
