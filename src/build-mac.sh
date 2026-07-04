#!/bin/bash
# ============================================================================
# build-mac.sh — Native macOS build for legacy atomicdex
# ============================================================================
# Reference path: mirrors the upstream CIPIG macOS CI shape, but swaps in the
# locally-built KDF instead of the upstream prebuilt Gleec artifact.
#
# Usage:
#   ./build-mac.sh                  # full build (KDF + desktop)
#   ./build-mac.sh --kdf-only       # KDF only
#   ./build-mac.sh --desktop-only   # desktop only (needs output/mac/kdf)
#   ./build-mac.sh --yes            # skip prompts
#   ./build-mac.sh --install-deps   # install missing brew deps, then exit
#   ./build-mac.sh --dry-run        # print plan only
#
# Output:
#   output/mac/kdf
#   output/mac/kdf.sha256
#   output/mac/*.app
#   output/mac/*.dmg                # if packaging succeeds
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
CONFIG_DIR="${PROJECT_DIR}/config"
SOURCES_JSON="${CONFIG_DIR}/sources.json"

FLAG_YES=false
FLAG_KDF_ONLY=false
FLAG_DESKTOP_ONLY=false
FLAG_DRY_RUN=false
FLAG_INSTALL_DEPS_ONLY=false

if [ "${BUILD_YES:-}" = "1" ]; then FLAG_YES=true; fi

OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}/mac"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}/mac"
BUILD_ROOT="${BUILD_DIR:-${PROJECT_DIR}/.build}/mac"
SDK_ROOT="${BUILD_ROOT}/sdk"
LOCAL_PREFIX="${BUILD_ROOT}/local"
SHIM_DIR="${BUILD_ROOT}/shims"

BUILD_CPUS="${BUILD_CPUS:-}"
if [ -z "${BUILD_CPUS}" ]; then
    TOTAL_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    BUILD_CPUS=$(( TOTAL_CPUS / 2 ))
    [ "${BUILD_CPUS}" -lt 1 ] && BUILD_CPUS=1
fi

for arg in "$@"; do
    case "$arg" in
        --yes|-y)            FLAG_YES=true ;;
        --kdf-only)          FLAG_KDF_ONLY=true ;;
        --desktop-only)      FLAG_DESKTOP_ONLY=true ;;
        --dry-run)           FLAG_DRY_RUN=true ;;
        --install-deps)      FLAG_INSTALL_DEPS_ONLY=true ;;
        --help|-h)
            sed -n '2,22p' "$0" | grep -v '^#!/'
            exit 0
            ;;
    esac
done

KDF_REPO="${KDF_REPO:-}"
KDF_COMMIT="${KDF_COMMIT:-}"
DESKTOP_REPO="${DESKTOP_REPO:-}"
DESKTOP_COMMIT="${DESKTOP_COMMIT:-}"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$BUILD_ROOT" "$SDK_ROOT" "$LOCAL_PREFIX"
export PATH="$HOME/.cargo/bin:$PATH"
exec > >(tee -a "${LOG_DIR}/build.log") 2>&1

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_CYAN='\033[36m'

step()  { echo -e "${C_BOLD}${C_CYAN}Step $1${C_RESET}: $2"; }
ok()    { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }
fail()  { echo -e "  ${C_RED}✗${C_RESET} $1"; }
info()  { echo -e "    $1"; }
die()   { fail "$1"; exit 1; }

MISSING_BREW_PACKAGES=()
MISSING_NOTES=()
HAVE_BREW=true
PYTHON_BIN=""
QT_INSTALL_CMAKE_PATH_RESOLVED=""
QT_ROOT_RESOLVED=""
SDK_PATH_RESOLVED=""
HOST_ARCH=""
RUST_TARGET=""
VCPKG_TRIPLET=""

append_unique() {
    local value="$1"
    shift || true
    local existing
    for existing in "$@"; do
        [ "$existing" = "$value" ] && return 0
    done
    return 1
}

add_missing_formula() {
    local formula="$1"
    local note="$2"
    if ! append_unique "$formula" "${MISSING_BREW_PACKAGES[@]:-}"; then
        MISSING_BREW_PACKAGES+=("$formula")
        MISSING_NOTES+=("$formula — $note")
    fi
}

host_setup() {
    case "$(uname -m)" in
        arm64)
            HOST_ARCH="arm64"
            RUST_TARGET="aarch64-apple-darwin"
            VCPKG_TRIPLET="arm64-osx"
            ;;
        x86_64)
            HOST_ARCH="x86_64"
            RUST_TARGET="x86_64-apple-darwin"
            VCPKG_TRIPLET="x64-osx"
            ;;
        *)
            die "Unsupported macOS architecture: $(uname -m)"
            ;;
    esac
}

read_sources() {
    [ -f "$SOURCES_JSON" ] || die "Missing sources config: $SOURCES_JSON"

    if [ -z "$KDF_REPO" ]; then
        KDF_REPO="$(jq -r '.kdf.repo' "$SOURCES_JSON")"
    fi
    if [ -z "$KDF_COMMIT" ]; then
        KDF_COMMIT="$(jq -r '.kdf.commit' "$SOURCES_JSON")"
    fi
    if [ -z "$DESKTOP_REPO" ]; then
        DESKTOP_REPO="$(jq -r '.desktop.repo' "$SOURCES_JSON")"
    fi
    if [ -z "$DESKTOP_COMMIT" ]; then
        DESKTOP_COMMIT="$(jq -r '.desktop.commit' "$SOURCES_JSON")"
    fi
}

check_python() {
    if command -v python3.11 >/dev/null 2>&1 && python3.11 -c 'import distutils' >/dev/null 2>&1; then
        ok "python3.11 — upstream-compatible Python"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1 && python3 -c 'import distutils' >/dev/null 2>&1; then
        ok "python3 — usable Python with distutils"
        return 0
    fi

    fail "Python with distutils support not found"
    add_missing_formula "python@3.11" "upstream CI uses Python 3.11; newer Python drops distutils"
    return 1
}

check_qt() {
    if [ -n "${QT_INSTALL_CMAKE_PATH:-}" ] && [ -f "${QT_INSTALL_CMAKE_PATH}/Qt5/Qt5Config.cmake" ]; then
        ok "Qt5 — from QT_INSTALL_CMAKE_PATH"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        local qt_prefix
        qt_prefix="$(brew --prefix qt@5 2>/dev/null || true)"
        if [ -n "$qt_prefix" ] && [ -f "$qt_prefix/lib/cmake/Qt5/Qt5Config.cmake" ] && [ -x "$qt_prefix/bin/macdeployqt" ]; then
            ok "qt@5 — Homebrew Qt5"
            return 0
        fi
    fi

    fail "Qt5 not found"
    add_missing_formula "qt@5" "desktop build needs Qt 5 + macdeployqt"
    return 1
}

check_all_deps() {
    echo ""
    echo -e "${C_BOLD}── Checking system dependencies ──${C_RESET}"
    echo ""

    echo -e "${C_BOLD}Platform:${C_RESET}"
    if [ "$(uname -s)" != "Darwin" ]; then
        die "This script only runs on macOS"
    fi
    ok "macOS $(sw_vers -productVersion 2>/dev/null || echo unknown) ($(uname -m))"

    echo ""
    echo -e "${C_BOLD}Xcode:${C_RESET}"
    if xcode-select -p >/dev/null 2>&1; then
        ok "Xcode Command Line Tools installed"
    else
        fail "Xcode Command Line Tools missing"
        MISSING_NOTES+=("Xcode CLI Tools — run: xcode-select --install")
    fi

    echo ""
    echo -e "${C_BOLD}Homebrew:${C_RESET}"
    if command -v brew >/dev/null 2>&1; then
        ok "Homebrew installed"
    else
        HAVE_BREW=false
        fail "Homebrew missing"
        MISSING_NOTES+=("Homebrew — install from https://brew.sh")
    fi

    echo ""
    echo -e "${C_BOLD}Build tools:${C_RESET}"
    command -v jq >/dev/null 2>&1        && ok "jq — config parsing"                || { fail "jq missing"; add_missing_formula "jq" "config parsing"; }
    command -v git >/dev/null 2>&1       && ok "git — source checkout"             || { fail "git missing"; add_missing_formula "git" "source checkout"; }
    command -v curl >/dev/null 2>&1      && ok "curl — downloads"                  || { fail "curl missing"; add_missing_formula "curl" "downloads"; }
    command -v cmake >/dev/null 2>&1     && ok "cmake — configure/build"           || { fail "cmake missing"; add_missing_formula "cmake" "configure/build"; }
    command -v ninja >/dev/null 2>&1     && ok "ninja — build backend"             || { fail "ninja missing"; add_missing_formula "ninja" "build backend"; }
    command -v rustup >/dev/null 2>&1    && ok "rustup — Rust toolchain"           || { fail "rustup missing"; add_missing_formula "rustup-init" "Rust toolchain"; }
    command -v cargo >/dev/null 2>&1     && ok "cargo — Rust build"                || { fail "cargo missing"; add_missing_formula "rustup-init" "Rust build"; }
    command -v autoconf >/dev/null 2>&1  && ok "autoconf — libwally build"         || { fail "autoconf missing"; add_missing_formula "autoconf" "libwally build"; }
    command -v automake >/dev/null 2>&1  && ok "automake — libwally build"         || { fail "automake missing"; add_missing_formula "automake" "libwally build"; }
    command -v glibtool >/dev/null 2>&1  && ok "glibtool — GNU libtool"            || { fail "glibtool missing"; add_missing_formula "libtool" "GNU libtool on macOS"; }
    command -v glibtoolize >/dev/null 2>&1 && ok "glibtoolize — GNU libtoolize"    || { fail "glibtoolize missing"; add_missing_formula "libtool" "GNU libtoolize on macOS"; }

    if $HAVE_BREW; then
        if brew list --formula autoconf-archive >/dev/null 2>&1; then
            ok "autoconf-archive — vcpkg dependency"
        else
            fail "autoconf-archive missing"
            add_missing_formula "autoconf-archive" "vcpkg dependency"
        fi
    fi

    check_python || true

    if ! $FLAG_KDF_ONLY; then
        echo ""
        echo -e "${C_BOLD}Desktop-specific:${C_RESET}"
        check_qt || true
    fi

    echo ""
    if [ "${#MISSING_NOTES[@]}" -eq 0 ] && [ "${#MISSING_BREW_PACKAGES[@]}" -eq 0 ]; then
        echo -e "${C_GREEN}All dependencies present.${C_RESET}"
    else
        echo -e "${C_YELLOW}Missing prerequisites detected.${C_RESET}"
    fi
}

print_missing_summary() {
    local note
    echo ""
    echo -e "${C_YELLOW}Missing items:${C_RESET}"
    for note in "${MISSING_NOTES[@]:-}"; do
        [ -n "$note" ] && echo "  - $note"
    done
    if [ "${#MISSING_BREW_PACKAGES[@]}" -gt 0 ]; then
        echo ""
        echo "  brew install ${MISSING_BREW_PACKAGES[*]}"
    fi
}

install_missing_deps() {
    if [ "${#MISSING_BREW_PACKAGES[@]}" -eq 0 ]; then
        return 0
    fi

    if ! $HAVE_BREW; then
        die "Homebrew is required before I can install missing packages"
    fi

    print_missing_summary

    if $FLAG_DRY_RUN; then
        info "[DRY RUN] would install missing Homebrew packages"
        return 0
    fi

    if ! $FLAG_YES; then
        echo ""
        echo -n "Install missing packages now? [Y/n] "
        read -r answer
        if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
            die "Cannot continue without these dependencies"
        fi
    fi

    local formula
    for formula in "${MISSING_BREW_PACKAGES[@]}"; do
        if brew list --formula "$formula" >/dev/null 2>&1; then
            info "$formula already installed"
        else
            info "Installing $formula..."
            brew install "$formula"
        fi

        if [ "$formula" = "rustup-init" ] && ! command -v rustup >/dev/null 2>&1; then
            info "Bootstrapping Rust toolchain..."
            rustup-init -y
            export PATH="$HOME/.cargo/bin:$PATH"
        fi
    done
}

resolve_python() {
    if command -v python3.11 >/dev/null 2>&1 && python3.11 -c 'import distutils' >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3.11)"
        return
    fi
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import distutils' >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3)"
        return
    fi

    if command -v brew >/dev/null 2>&1; then
        local candidate
        candidate="$(brew --prefix python@3.11 2>/dev/null || true)/bin/python3.11"
        if [ -x "$candidate" ] && "$candidate" -c 'import distutils' >/dev/null 2>&1; then
            PYTHON_BIN="$candidate"
            return
        fi
    fi

    die "Could not resolve a usable Python interpreter"
}

resolve_qt() {
    local qt_prefix=""
    local qt_macdeploy=""

    if [ -n "${QT_INSTALL_CMAKE_PATH:-}" ] && [ -f "${QT_INSTALL_CMAKE_PATH}/Qt5/Qt5Config.cmake" ]; then
        QT_INSTALL_CMAKE_PATH_RESOLVED="$QT_INSTALL_CMAKE_PATH"
        if [ -n "${QT_ROOT:-}" ] && [ -x "${QT_ROOT}/clang_64/bin/macdeployqt" ]; then
            QT_ROOT_RESOLVED="$QT_ROOT"
            return
        fi
        qt_prefix="$(cd "${QT_INSTALL_CMAKE_PATH}/../.." && pwd)"
        qt_macdeploy="$qt_prefix/bin/macdeployqt"
        [ -x "$qt_macdeploy" ] || die "QT_INSTALL_CMAKE_PATH is set, but macdeployqt was not found next to it"
    else
        qt_prefix="$(brew --prefix qt@5 2>/dev/null || true)"
        [ -n "$qt_prefix" ] || die "qt@5 not installed"
        [ -f "$qt_prefix/lib/cmake/Qt5/Qt5Config.cmake" ] || die "Qt5Config.cmake not found in qt@5"
        qt_macdeploy="$qt_prefix/bin/macdeployqt"
        [ -x "$qt_macdeploy" ] || die "macdeployqt not found in qt@5"
        QT_INSTALL_CMAKE_PATH_RESOLVED="$qt_prefix/lib/cmake"
    fi

    QT_ROOT_RESOLVED="${BUILD_ROOT}/Qt/5.15.2"
    mkdir -p "${QT_ROOT_RESOLVED}/clang_64/bin" "${BUILD_ROOT}/Qt/Tools/QtInstallerFramework"
    ln -sf "$qt_macdeploy" "${QT_ROOT_RESOLVED}/clang_64/bin/macdeployqt"
}

ensure_sdk() {
    if [ -n "${MACOS_SDK_PATH:-}" ] && [ -d "${MACOS_SDK_PATH}" ]; then
        SDK_PATH_RESOLVED="$MACOS_SDK_PATH"
        ok "Using MACOS_SDK_PATH → $SDK_PATH_RESOLVED"
        return
    fi

    if [ -d "$HOME/sdk/MacOSX11.3.sdk" ]; then
        SDK_PATH_RESOLVED="$HOME/sdk/MacOSX11.3.sdk"
        ok "Using cached SDK → $SDK_PATH_RESOLVED"
        return
    fi

    if [ -d "${SDK_ROOT}/MacOSX11.3.sdk" ]; then
        SDK_PATH_RESOLVED="${SDK_ROOT}/MacOSX11.3.sdk"
        ok "Using project SDK → $SDK_PATH_RESOLVED"
        return
    fi

    if $FLAG_DRY_RUN; then
        info "[DRY RUN] would download MacOSX11.3.sdk"
        SDK_PATH_RESOLVED="${SDK_ROOT}/MacOSX11.3.sdk"
        return
    fi

    step "prep" "Downloading MacOSX11.3 SDK (upstream CI parity)..."
    local sdk_tar="${SDK_ROOT}/MacOSX11.3.sdk.tar.xz"
    curl -L "https://github.com/phracker/MacOSX-SDKs/releases/download/11.3/MacOSX11.3.sdk.tar.xz" -o "$sdk_tar"
    tar -xf "$sdk_tar" -C "$SDK_ROOT"
    SDK_PATH_RESOLVED="${SDK_ROOT}/MacOSX11.3.sdk"
    ok "SDK ready → $SDK_PATH_RESOLVED"
}

prepare_shims() {
    mkdir -p "$SHIM_DIR"
    ln -sf "$PYTHON_BIN" "$SHIM_DIR/python"
    ln -sf "$(command -v glibtoolize)" "$SHIM_DIR/libtoolize"
    ln -sf "$(command -v glibtool)" "$SHIM_DIR/libtool"
    export PATH="$SHIM_DIR:$PATH"
}

checkout_repo() {
    local repo_url="$1"
    local repo_dir="$2"
    local ref="$3"

    if [ -d "$repo_dir/.git" ]; then
        info "Updating $(basename "$repo_dir")..."
        (
            cd "$repo_dir"
            git fetch origin
            git checkout "$ref"
            git reset --hard "$ref"
            git clean -fdx
            git submodule sync --recursive
            git submodule update --init --recursive
        )
    else
        info "Cloning $(basename "$repo_dir") — full history, pinned checkout"
        git clone "$repo_url" "$repo_dir"
        (
            cd "$repo_dir"
            git checkout "$ref"
            git submodule sync --recursive
            git submodule update --init --recursive
        )
    fi
}

build_kdf() {
    local kdf_dir="${BUILD_ROOT}/kdf"

    step "3/6" "Preparing KDF source (${KDF_COMMIT})"
    checkout_repo "$KDF_REPO" "$kdf_dir" "$KDF_COMMIT"
    ok "KDF source at $(cd "$kdf_dir" && git rev-parse --short HEAD)"

    step "4/6" "Building KDF for ${HOST_ARCH} (${RUST_TARGET})"
    (
        cd "$kdf_dir"
        rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
        cargo build --release --target "$RUST_TARGET" -p mm2_bin_lib -j "$BUILD_CPUS"
    )

    cp "$kdf_dir/target/${RUST_TARGET}/release/kdf" "$OUTPUT_DIR/kdf"
    shasum -a 256 "$OUTPUT_DIR/kdf" | awk '{print $1}' > "$OUTPUT_DIR/kdf.sha256"
    ok "KDF → $OUTPUT_DIR/kdf"
    ok "SHA256: $(cat "$OUTPUT_DIR/kdf.sha256")"
}

apply_local_kdf_patch() {
    local desktop_dir="$1"
    mkdir -p "$desktop_dir/assets/tools/kdf"
    cp "$OUTPUT_DIR/kdf" "$desktop_dir/assets/tools/kdf/kdf"

    "$PYTHON_BIN" - "$desktop_dir/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

old_block = '''if (APPLE)
    FetchContent_Declare(kdf
            URL https://devbuilds.gleec.com/dev/kdf_a12695e-mac-x86-64.zip)
elseif (UNIX AND NOT APPLE)
    FetchContent_Declare(kdf
            URL https://devbuilds.gleec.com/dev/kdf_a12695e-linux-x86-64.zip)
else ()
    FetchContent_Declare(kdf
            URL https://devbuilds.gleec.com/dev/kdf_a12695e-win-x86-64.zip)
endif ()
'''
new_block = '# Local KDF is staged by build-mac.sh; do not fetch upstream devbuilds.\n'

old_make_available = 'FetchContent_MakeAvailable(kdf jl777-coins qmaterial)'
new_make_available = 'FetchContent_MakeAvailable(jl777-coins qmaterial)'

old_copy = '    configure_file(${kdf_SOURCE_DIR}/kdf ${CMAKE_CURRENT_SOURCE_DIR}/assets/tools/kdf/${DEX_API} COPYONLY)'
new_copy = '    configure_file(${CMAKE_CURRENT_SOURCE_DIR}/assets/tools/kdf/kdf ${CMAKE_CURRENT_SOURCE_DIR}/assets/tools/kdf/${DEX_API} COPYONLY)'

if old_block not in text:
    raise SystemExit('kdf FetchContent block not found in CMakeLists.txt')
if old_make_available not in text:
    raise SystemExit('FetchContent_MakeAvailable block not found in CMakeLists.txt')
if old_copy not in text:
    raise SystemExit('local kdf configure_file seam not found in CMakeLists.txt')

text = text.replace(old_block, new_block, 1)
text = text.replace(old_make_available, new_make_available, 1)
text = text.replace(old_copy, new_copy, 1)
path.write_text(text)
PY
}

build_libwally() {
    local libwally_dir="${BUILD_ROOT}/libwally-core"

    if [ -f "${LOCAL_PREFIX}/lib/libwallycore.a" ] && [ -f "${LOCAL_PREFIX}/include/wally_core.h" ]; then
        ok "libwally already installed in ${LOCAL_PREFIX}"
        return
    fi

    step "5/6" "Building libwally-core into local prefix"
    if [ -d "$libwally_dir/.git" ]; then
        (
            cd "$libwally_dir"
            git fetch origin --tags
            git checkout release_0.9.2
            git reset --hard release_0.9.2
            git clean -fdx
            git submodule sync --recursive
            git submodule update --init --recursive
        )
    else
        git clone --recurse-submodules --branch release_0.9.2 https://github.com/ElementsProject/libwally-core "$libwally_dir"
    fi

    (
        cd "$libwally_dir"
        env PATH="$SHIM_DIR:$PATH" LIBTOOL=glibtool LIBTOOLIZE=glibtoolize CC=clang CXX=clang++ ./tools/autogen.sh
        env PATH="$SHIM_DIR:$PATH" LIBTOOL=glibtool LIBTOOLIZE=glibtoolize CC=clang CXX=clang++ \
            ./configure --disable-shared --disable-tests --prefix="$LOCAL_PREFIX"
        make -j"$BUILD_CPUS"
        make install
    )

    ok "libwally installed → ${LOCAL_PREFIX}"
}

build_desktop() {
    local desktop_dir="${BUILD_ROOT}/desktop"
    local build_dir="${desktop_dir}/ci_tools_atomic_dex/build-Release"
    local dmg_found=""
    local app_found=""

    [ -f "$OUTPUT_DIR/kdf" ] || die "KDF binary not found at $OUTPUT_DIR/kdf — run: ./commands/build/command.sh native kdf"

    resolve_python
    resolve_qt
    ensure_sdk
    prepare_shims
    build_libwally

    step "6/6" "Preparing desktop source (${DESKTOP_COMMIT})"
    checkout_repo "$DESKTOP_REPO" "$desktop_dir" "$DESKTOP_COMMIT"
    apply_local_kdf_patch "$desktop_dir"
    ok "Desktop source at $(cd "$desktop_dir" && git rev-parse --short HEAD)"

    info "Using SDK: $SDK_PATH_RESOLVED"
    info "Using Qt CMake path: $QT_INSTALL_CMAKE_PATH_RESOLVED"
    info "Using vcpkg triplet: $VCPKG_TRIPLET"

    export QT_INSTALL_CMAKE_PATH="$QT_INSTALL_CMAKE_PATH_RESOLVED"
    export QT_ROOT="$QT_ROOT_RESOLVED"
    export MACOSX_DEPLOYMENT_TARGET=11.3
    export CC=clang
    export CXX=clang++
    export CMAKE_BUILD_TYPE=Release
    export VCPKG_BUILD_TYPE=release
    export VCPKG_ROOT="${desktop_dir}/ci_tools_atomic_dex/vcpkg-repo"
    export VCPKG_DEFAULT_BINARY_CACHE="${BUILD_ROOT}/vcpkg-cache"
    export CMAKE_INCLUDE_PATH="${LOCAL_PREFIX}/include"
    export CMAKE_LIBRARY_PATH="${LOCAL_PREFIX}/lib"
    export LIBRARY_PATH="${LOCAL_PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export CPATH="${LOCAL_PREFIX}/include${CPATH:+:$CPATH}"
    export PKG_CONFIG_PATH="${LOCAL_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export SDKROOT="$SDK_PATH_RESOLVED"

    if [ ! -x "${VCPKG_ROOT}/vcpkg" ]; then
        step "6a" "Bootstrapping vcpkg"
        (
            cd "$desktop_dir/ci_tools_atomic_dex/vcpkg-repo"
            ./bootstrap-vcpkg.sh
        )
    fi

    step "6b" "Installing vcpkg dependencies"
    (
        cd "$desktop_dir"
        git checkout -- vcpkg.json
        "${VCPKG_ROOT}/vcpkg" install \
            --triplet "$VCPKG_TRIPLET" \
            --overlay-ports "$desktop_dir/ci_tools_atomic_dex/vcpkg-custom-ports/ports" \
            --overlay-triplets "$desktop_dir/cmake"
    )

    step "6c" "Configuring desktop build"
    rm -rf "$build_dir"
    cmake -S "$desktop_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH_RESOLVED" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.3 \
        -DCMAKE_PREFIX_PATH="$QT_INSTALL_CMAKE_PATH_RESOLVED" \
        -DCMAKE_INCLUDE_PATH="${LOCAL_PREFIX}/include" \
        -DCMAKE_LIBRARY_PATH="${LOCAL_PREFIX}/lib"

    step "6d" "Building desktop app"
    cmake --build "$build_dir" --config Release -j "$BUILD_CPUS"

    step "6e" "Installing / packaging desktop app"
    if cmake --install "$build_dir"; then
        ok "Desktop install/package step completed"
    else
        warn "Desktop install/package step failed — will still collect any built .app bundle"
    fi

    dmg_found="$(find "$desktop_dir/bundled/osx" -maxdepth 1 -name '*.dmg' 2>/dev/null | head -1 || true)"
    app_found="$(find "$build_dir" -maxdepth 4 -name '*.app' 2>/dev/null | head -1 || true)"

    if [ -n "$app_found" ]; then
        rm -rf "$OUTPUT_DIR/$(basename "$app_found")"
        cp -R "$app_found" "$OUTPUT_DIR/"
        ok "App bundle → $OUTPUT_DIR/$(basename "$app_found")"
    fi

    if [ -n "$dmg_found" ]; then
        cp "$dmg_found" "$OUTPUT_DIR/"
        ok "DMG → $OUTPUT_DIR/$(basename "$dmg_found")"
    fi

    if [ -z "$app_found" ] && [ -z "$dmg_found" ]; then
        die "Desktop build completed without producing a .app or .dmg artifact"
    fi
}

main() {
    echo ""
    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║  Native macOS Build                                     ║${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""

    host_setup

    step "1/6" "Checking platform"
    check_all_deps

    if [ "${#MISSING_NOTES[@]}" -gt 0 ] || [ "${#MISSING_BREW_PACKAGES[@]}" -gt 0 ]; then
        install_missing_deps
        MISSING_BREW_PACKAGES=()
        MISSING_NOTES=()
        HAVE_BREW=true
        step "2/6" "Re-checking dependencies"
        check_all_deps
        if [ "${#MISSING_NOTES[@]}" -gt 0 ] || [ "${#MISSING_BREW_PACKAGES[@]}" -gt 0 ]; then
            print_missing_summary
            die "Dependencies are still missing"
        fi
        if $FLAG_INSTALL_DEPS_ONLY; then
            echo ""
            ok "Dependencies installed. Re-run the build."
            exit 0
        fi
    fi

    if $FLAG_INSTALL_DEPS_ONLY; then
        echo ""
        ok "Dependencies already satisfied. Nothing to do."
        exit 0
    fi

    read_sources
    echo ""
    echo "  CPUs: ${BUILD_CPUS}  |  host: ${HOST_ARCH}  |  KDF: ${KDF_COMMIT}  |  Desktop: ${DESKTOP_COMMIT}"
    echo ""

    if $FLAG_DRY_RUN; then
        echo ""
        echo -e "${C_GREEN}[DRY RUN] Ready.${C_RESET}"
        $FLAG_KDF_ONLY && echo "  → would build KDF only"
        $FLAG_DESKTOP_ONLY && echo "  → would build desktop only"
        ! $FLAG_KDF_ONLY && ! $FLAG_DESKTOP_ONLY && echo "  → would build KDF + desktop"
        exit 0
    fi

    if ! $FLAG_DESKTOP_ONLY; then
        build_kdf
    fi

    if ! $FLAG_KDF_ONLY; then
        build_desktop
    fi

    echo ""
    echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}║  BUILD COMPLETE                                        ║${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "  Output: ${OUTPUT_DIR}/"
    ls -lh "$OUTPUT_DIR" 2>/dev/null || true
    echo ""
}

main
