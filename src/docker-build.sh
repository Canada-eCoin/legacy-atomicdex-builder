#!/bin/bash
# docker-build.sh — Build inside Docker (assumes deps pre-installed, non-interactive)
# Usage: docker-build.sh kdf       # KDF engine only
#        docker-build.sh desktop   # desktop AppImage only (needs KDF at output/linux/kdf)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

# ── Source shared library ────────────────────────────────────
source "${SCRIPT_DIR}/_build-lib.sh"

TARGET="${1:-}"
if [ "$TARGET" != "kdf" ] && [ "$TARGET" != "desktop" ]; then
    echo "Usage: docker-build.sh <kdf|desktop>"
    exit 1
fi

# ── Config ────────────────────────────────────────────────────
CONFIG_DIR="${PROJECT_DIR}/config"
SOURCES_JSON="${CONFIG_DIR}/sources.json"
read_sources

BUILD_CPUS="${BUILD_CPUS:-$(( $(nproc 2>/dev/null || echo 4) / 3 ))}"
[ "$BUILD_CPUS" -lt 1 ] && BUILD_CPUS=1

OUTPUT_DIR="${PROJECT_DIR}/output/linux"
BUILD_DIR="${PROJECT_DIR}/.build"
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"

# ── Colors ────────────────────────────────────────────────────
C_RESET='\033[0m'; C_BOLD='\033[1m'
C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_CYAN='\033[36m'
step()  { echo -e "${C_BOLD}${C_CYAN}→${C_RESET} $1"; }
ok()    { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }
fail()  { echo -e "  ${C_RED}✗${C_RESET} $1"; }

# ═══════════════════════════════════════════════════════════════
# Build: KDF
# ═══════════════════════════════════════════════════════════════
build_kdf() {
    clone_source "kdf" "$KDF_REPO" "$KDF_COMMIT"
    apply_patches_to "${CONFIG_DIR}/patches" "${BUILD_DIR}/kdf"

    local kdf_dir="${BUILD_DIR}/kdf"
    step "compiling KDF (Rust, ${BUILD_CPUS} CPUs)"

    cd "$kdf_dir"
    export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"

    cargo build --release \
        --target x86_64-unknown-linux-gnu \
        -p mm2_bin_lib \
        -j "$BUILD_CPUS" 2>&1 | sed 's/^/  /'

    cp "target/x86_64-unknown-linux-gnu/release/kdf" "${OUTPUT_DIR}/kdf"
    sha256sum "${OUTPUT_DIR}/kdf" | cut -d" " -f1 > "${OUTPUT_DIR}/kdf.sha256"

    local size; size=$(du -h "${OUTPUT_DIR}/kdf" | cut -f1)
    ok "KDF built — ${size}"
    ok "SHA256: $(cat "${OUTPUT_DIR}/kdf.sha256")"
}

# ═══════════════════════════════════════════════════════════════
# Build: Desktop
# ═══════════════════════════════════════════════════════════════
build_desktop() {
    clone_source "desktop" "$DESKTOP_REPO" "$DESKTOP_COMMIT"
    apply_patches_to "${CONFIG_DIR}/patches" "${BUILD_DIR}/desktop"
    local dtop_dir="${BUILD_DIR}/desktop"
    cd "$dtop_dir"

    stage_kdf "$dtop_dir" "${OUTPUT_DIR}/kdf"
    strip_kdf_fetchcontent "$dtop_dir"
    ensure_libwally
    ensure_cmake
    ensure_vcpkg "$dtop_dir"
    ensure_linuxdeployqt "$dtop_dir"
    fix_nss_symlinks
    fix_qtwebengine_rpath

    # ── Compile ─────────────────────────────────────────────
    cd "$dtop_dir"  # ensure_* functions may have changed CWD
    step "compiling desktop (cmake + ninja, ${BUILD_CPUS} CPUs)"
    mkdir -p ci_tools_atomic_dex/build-Release
    cd ci_tools_atomic_dex/build-Release

    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD_LIBRARIES="-lssl -lcrypto" \
        ../../ 2>&1 | sed 's/^/  /'

    cmake --build . --config Release -j"$BUILD_CPUS" 2>&1 | sed 's/^/  /'

    stage_kdf_appdir "$dtop_dir"

    # ninja install runs linuxdeployqt + appimagetool.
    # The cmake post-install rename can fail if the AppImage naming
    # convention doesn't match (empty VERSION field = double dash).
    # The AppImage is still created — we just need to find it.
    ninja install 2>&1 | sed 's/^/  /' || true

    # ── Fix QtWebEngineProcess RPATH ────────────────────────
    # linuxdeployqt bundles Qt5 libs but doesn't set RPATH on
    # QtWebEngineProcess. Patch it in the AppDir, then repackage.
    local qtwep_appdir="bin/AntaraAtomicDexAppDir/usr/libexec/QtWebEngineProcess"
    local appimagetool="${dtop_dir}/ci_tools_atomic_dex/linux_misc/squashfs-root/usr/bin/appimagetool"
    if [ -f "$qtwep_appdir" ] && [ -f "$appimagetool" ]; then
        (apt-get update -qq && apt-get install -y -qq desktop-file-utils) 2>/dev/null || true
        step "patching QtWebEngineProcess RPATH"
        patchelf --set-rpath '$ORIGIN/../lib' "$qtwep_appdir"
        ok "QtWebEngineProcess RPATH set → \$ORIGIN/../lib"
        step "re-packaging AppImage with patched binary"
        "$appimagetool" bin/AntaraAtomicDexAppDir komodo-wallet-desktop-x86_64.AppImage 2>&1 | sed 's/^/  /' || true
    fi

    # ── Package ─────────────────────────────────────────────
    # Find the AppImage whatever it's named
    local appimage
    appimage=$(find . -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)
    if [ -n "$appimage" ] && [ -f "$appimage" ]; then
        cp "$appimage" "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage"
        ok "AppImage packaged"
    else
        warn "no AppImage produced — raw binary only"
    fi

    if [ -f bin/AntaraAtomicDexAppDir/usr/bin/komodo-wallet ]; then
        cp bin/AntaraAtomicDexAppDir/usr/bin/komodo-wallet "${OUTPUT_DIR}/komodo-wallet-desktop" 2>/dev/null || true
    fi

    sha256sum "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage" 2>/dev/null | \
        cut -d" " -f1 > "${OUTPUT_DIR}/komodo-wallet-desktop.sha256" || true

    local size
    size=$(du -h "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage" 2>/dev/null | cut -f1 || echo "unknown")
    ok "desktop built — ${size}"
}

# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${C_BOLD}═══ AtomicDEX — Docker Build: ${TARGET} ═══${C_RESET}"
echo ""

case "$TARGET" in
    kdf)     build_kdf ;;
    desktop) build_desktop ;;
esac

echo ""
echo -e "${C_BOLD}${C_GREEN}═══ DONE — ${TARGET} ═══${C_RESET}"
echo ""
ls -lh "${OUTPUT_DIR}/" 2>/dev/null || echo "  (empty)"
echo ""
