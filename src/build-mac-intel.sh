#!/bin/bash
# ============================================================================
# build-mac-intel.sh — Intel/x86_64 macOS build for legacy atomicdex
# ============================================================================
# Reference path: mirrors the upstream CIPIG macOS CI shape, but swaps in the
# locally-built KDF instead of the upstream prebuilt Gleec artifact.
#
# Usage:
#   ./build-mac-intel.sh                  # full Intel build (KDF + desktop)
#   ./build-mac-intel.sh --kdf-only       # Intel KDF only
#   ./build-mac-intel.sh --desktop-only   # Intel desktop only (needs output/mac-intel/kdf)
#   ./build-mac-intel.sh --yes            # skip prompts
#   ./build-mac-intel.sh --install-deps   # install missing brew deps, then exit
#   ./build-mac-intel.sh --dry-run        # print plan only
#
# Output:
#   output/mac-intel/kdf
#   output/mac-intel/kdf.sha256
#   output/mac-intel/*.app
#   output/mac-intel/*.dmg                # if packaging succeeds
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

OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}/mac-intel"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}/mac-intel"
BUILD_ROOT="${BUILD_DIR:-${PROJECT_DIR}/.build}/mac-intel"
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
BUILD_ARCH=""
BUILD_RUST_TARGET=""
BUILD_VCPKG_TRIPLET=""
BUILD_CMAKE_OSX_ARCH=""
QT_VERSION="5.15.2"

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
        arm64|x86_64)
            HOST_ARCH="$(uname -m)"
            RUST_TARGET="x86_64-apple-darwin"
            VCPKG_TRIPLET="x64-osx"
            BUILD_ARCH="x86_64"
            BUILD_RUST_TARGET="x86_64-apple-darwin"
            BUILD_VCPKG_TRIPLET="x64-osx"
            BUILD_CMAKE_OSX_ARCH="x86_64"
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

qt_cmake_dir_is_complete() {
    local cmake_dir="$1"
    [ -f "$cmake_dir/Qt5/Qt5Config.cmake" ] || return 1
    [ -f "$cmake_dir/Qt5Charts/Qt5ChartsConfig.cmake" ] || return 1
    [ -f "$cmake_dir/Qt5WebEngine/Qt5WebEngineConfig.cmake" ] || return 1
    [ -f "$cmake_dir/Qt5WebEngineCore/Qt5WebEngineCoreConfig.cmake" ] || return 1
    [ -f "$cmake_dir/Qt5WebEngineWidgets/Qt5WebEngineWidgetsConfig.cmake" ] || return 1
    return 0
}

qt_aqt_root() {
    echo "${BUILD_ROOT}/Qt/${QT_VERSION}"
}

qt_aqt_cmake_dir() {
    echo "$(qt_aqt_root)/clang_64/lib/cmake"
}

check_qt() {
    if [ -n "${QT_INSTALL_CMAKE_PATH:-}" ] && qt_cmake_dir_is_complete "$QT_INSTALL_CMAKE_PATH"; then
        ok "Qt ${QT_VERSION} + WebEngine — from QT_INSTALL_CMAKE_PATH"
        return 0
    fi

    local aqt_cmake
    aqt_cmake="$(qt_aqt_cmake_dir)"
    if qt_cmake_dir_is_complete "$aqt_cmake"; then
        ok "Qt ${QT_VERSION} + WebEngine — cached local AQT install"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        local qt_prefix
        qt_prefix="$(brew --prefix qt@5 2>/dev/null || true)"
        if [ -n "$qt_prefix" ] && qt_cmake_dir_is_complete "$qt_prefix/lib/cmake" && [ -x "$qt_prefix/bin/macdeployqt" ]; then
            ok "qt@5 — Homebrew Qt5 with WebEngine"
            return 0
        fi
    fi

    warn "Qt ${QT_VERSION} + QtWebEngine not found locally — will download via aqtinstall during desktop build"
    return 0
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
    command -v protoc >/dev/null 2>&1    && ok "protoc — Protocol Buffers compiler" || { fail "protoc missing"; add_missing_formula "protobuf" "Protocol Buffers compiler"; }
    command -v rustup >/dev/null 2>&1    && ok "rustup — Rust toolchain"           || { fail "rustup missing"; add_missing_formula "rustup-init" "Rust toolchain"; }
    command -v cargo >/dev/null 2>&1     && ok "cargo — Rust build"                || { fail "cargo missing"; add_missing_formula "rustup-init" "Rust build"; }
    command -v autoconf >/dev/null 2>&1  && ok "autoconf — libwally build"         || { fail "autoconf missing"; add_missing_formula "autoconf" "libwally build"; }
    command -v automake >/dev/null 2>&1  && ok "automake — libwally build"         || { fail "automake missing"; add_missing_formula "automake" "libwally build"; }
    command -v glibtool >/dev/null 2>&1  && ok "glibtool — GNU libtool"            || { fail "glibtool missing"; add_missing_formula "libtool" "GNU libtool on macOS"; }
    command -v glibtoolize >/dev/null 2>&1 && ok "glibtoolize — GNU libtoolize"    || { fail "glibtoolize missing"; add_missing_formula "libtool" "GNU libtoolize on macOS"; }
    command -v gsed >/dev/null 2>&1         && ok "gsed — GNU sed (autotools)"         || { fail "gsed missing"; add_missing_formula "gnu-sed" "GNU sed on macOS"; }

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

set_build_arch_for_qt() {
    local source_kind="$1"

    if [ "$source_kind" = "aqt-clang_64" ] && [ "$HOST_ARCH" = "arm64" ]; then
        BUILD_ARCH="x86_64"
        BUILD_RUST_TARGET="x86_64-apple-darwin"
        BUILD_VCPKG_TRIPLET="x64-osx"
        BUILD_CMAKE_OSX_ARCH="x86_64"
        warn "Qt ${QT_VERSION} clang_64 is Intel-only; building desktop path for x86_64 parity"
    fi
}

install_qt_via_aqt() {
    local qt_root_base
    local aqt_venv
    qt_root_base="${BUILD_ROOT}/Qt"
    aqt_venv="${BUILD_ROOT}/aqt-venv"

    if qt_cmake_dir_is_complete "$(qt_aqt_cmake_dir)"; then
        return 0
    fi

    if $FLAG_DRY_RUN; then
        info "[DRY RUN] would install Qt ${QT_VERSION} + qtwebengine via aqtinstall"
        return 0
    fi

    resolve_python
    step "qt" "Installing Qt ${QT_VERSION} + WebEngine via aqtinstall"
    "$PYTHON_BIN" -m venv "$aqt_venv"
    "$aqt_venv/bin/python" -m pip install --upgrade pip
    "$aqt_venv/bin/python" -m pip install aqtinstall==3.1.1
    "$aqt_venv/bin/python" -m aqt install-qt mac desktop "$QT_VERSION" clang_64 -O "$qt_root_base" -m qtcharts debug_info qtwebengine

    qt_cmake_dir_is_complete "$(qt_aqt_cmake_dir)" || die "aqtinstall completed, but Qt WebEngine modules are still missing"
}

resolve_qt() {
    local qt_prefix=""
    local qt_macdeploy=""
    local aqt_root=""
    local aqt_cmake=""

    if [ -n "${QT_INSTALL_CMAKE_PATH:-}" ] && qt_cmake_dir_is_complete "$QT_INSTALL_CMAKE_PATH"; then
        QT_INSTALL_CMAKE_PATH_RESOLVED="$QT_INSTALL_CMAKE_PATH"
        if [ -n "${QT_ROOT:-}" ] && [ -x "${QT_ROOT}/clang_64/bin/macdeployqt" ]; then
            QT_ROOT_RESOLVED="$QT_ROOT"
            case "$QT_INSTALL_CMAKE_PATH" in
                */clang_64/*) set_build_arch_for_qt "aqt-clang_64" ;;
            esac
            return
        fi
        qt_prefix="$(cd "${QT_INSTALL_CMAKE_PATH}/../.." && pwd)"
        qt_macdeploy="$qt_prefix/bin/macdeployqt"
        [ -x "$qt_macdeploy" ] || die "QT_INSTALL_CMAKE_PATH is set, but macdeployqt was not found next to it"
        QT_ROOT_RESOLVED="$(dirname "$qt_prefix")"
        case "$QT_INSTALL_CMAKE_PATH" in
            */clang_64/*) set_build_arch_for_qt "aqt-clang_64" ;;
        esac
        return
    fi

    aqt_root="$(qt_aqt_root)"
    aqt_cmake="$(qt_aqt_cmake_dir)"
    if ! qt_cmake_dir_is_complete "$aqt_cmake"; then
        if command -v brew >/dev/null 2>&1; then
            qt_prefix="$(brew --prefix qt@5 2>/dev/null || true)"
            if [ -n "$qt_prefix" ] && qt_cmake_dir_is_complete "$qt_prefix/lib/cmake" && [ -x "$qt_prefix/bin/macdeployqt" ]; then
                QT_INSTALL_CMAKE_PATH_RESOLVED="$qt_prefix/lib/cmake"
                QT_ROOT_RESOLVED="${BUILD_ROOT}/Qt/${QT_VERSION}"
                mkdir -p "${QT_ROOT_RESOLVED}/clang_64/bin" "${BUILD_ROOT}/Qt/Tools/QtInstallerFramework"
                ln -sf "$qt_prefix/bin/macdeployqt" "${QT_ROOT_RESOLVED}/clang_64/bin/macdeployqt"
                return
            fi
        fi
        install_qt_via_aqt
    fi

    QT_INSTALL_CMAKE_PATH_RESOLVED="$aqt_cmake"
    QT_ROOT_RESOLVED="$aqt_root"
    [ -x "$QT_ROOT_RESOLVED/clang_64/bin/macdeployqt" ] || die "Qt install is missing macdeployqt"
    set_build_arch_for_qt "aqt-clang_64"
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

    step "4/6" "Building KDF for ${BUILD_ARCH} (${BUILD_RUST_TARGET})"
    (
        cd "$kdf_dir"
        rustup target add "$BUILD_RUST_TARGET" >/dev/null 2>&1 || true
        cargo build --release --target "$BUILD_RUST_TARGET" -p mm2_bin_lib -j "$BUILD_CPUS"
    )

    cp "$kdf_dir/target/${BUILD_RUST_TARGET}/release/kdf" "$OUTPUT_DIR/kdf"
    shasum -a 256 "$OUTPUT_DIR/kdf" | awk '{print $1}' > "$OUTPUT_DIR/kdf.sha256"
    ok "KDF → $OUTPUT_DIR/kdf"
    ok "SHA256: $(cat "$OUTPUT_DIR/kdf.sha256")"
}

apply_local_desktop_patches() {
    local desktop_dir="$1"
    mkdir -p "$desktop_dir/assets/tools/kdf"
    cp "$OUTPUT_DIR/kdf" "$desktop_dir/assets/tools/kdf/kdf_kwd"
    chmod +x "$desktop_dir/assets/tools/kdf/kdf_kwd" 2>/dev/null || true

    "$PYTHON_BIN" - "$desktop_dir/CMakeLists.txt" "$desktop_dir/ci_tools_atomic_dex/vcpkg-custom-ports/ports/cpprestsdk/portfile.cmake" <<'PY'
import sys
from pathlib import Path

cmake_path = Path(sys.argv[1])
portfile_path = Path(sys.argv[2])

cmake_text = cmake_path.read_text()
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
if old_block not in cmake_text:
    raise SystemExit('kdf FetchContent block not found in CMakeLists.txt')
if old_make_available not in cmake_text:
    raise SystemExit('FetchContent_MakeAvailable block not found in CMakeLists.txt')
if old_copy not in cmake_text:
    raise SystemExit('local kdf configure_file seam not found in CMakeLists.txt')
cmake_text = cmake_text.replace(old_block, new_block, 1)
cmake_text = cmake_text.replace(old_make_available, new_make_available, 1)
cmake_text = cmake_text.replace(old_copy, '', 1)
cmake_path.write_text(cmake_text)

port_text = portfile_path.read_text()
needle = 'vcpkg_cmake_configure(\n'
patch = 'vcpkg_replace_string("${SOURCE_PATH}/Release/cmake/cpprest_find_openssl.cmake"\n    "::SSL_COMP_free_compression_methods();"\n    "SSL_COMP_free_compression_methods();")\n\n' + needle
if '::SSL_COMP_free_compression_methods();' in port_text:
    port_text = port_text.replace('::SSL_COMP_free_compression_methods();', 'SSL_COMP_free_compression_methods();')
elif 'vcpkg_replace_string("${SOURCE_PATH}/Release/cmake/cpprest_find_openssl.cmake"' not in port_text:
    if needle not in port_text:
        raise SystemExit('cpprestsdk portfile configure seam not found')
    port_text = port_text.replace(needle, patch, 1)

openssl_opt = '        -DOPENSSL_ROOT_DIR=${CURRENT_INSTALLED_DIR}\n'
if '-DOPENSSL_ROOT_DIR=${CURRENT_INSTALLED_DIR}' not in port_text:
    anchor = '        -DCPPREST_EXPORT_DIR=share/cpprestsdk\n'
    if anchor not in port_text:
        raise SystemExit('cpprestsdk OPENSSL_ROOT_DIR seam not found')
    port_text = port_text.replace(anchor, anchor + openssl_opt, 1)

portfile_path.write_text(port_text)
PY
}

stage_kdf_in_app_bundle() {
    local app_bundle="$1"
    local target_dir="$app_bundle/Contents/Resources/assets/tools/kdf"

    mkdir -p "$target_dir"
    cp "$OUTPUT_DIR/kdf" "$target_dir/kdf_kwd"
    chmod +x "$target_dir/kdf_kwd" 2>/dev/null || true
    ok "KDF staged into app bundle → $target_dir/kdf_kwd"
}

show_vcpkg_failure_logs() {
    local root="$1"
    local log
    echo ""
    warn "vcpkg failed. Relevant log tails:"
    for log in \
        "$root/buildtrees/cpprestsdk/config-arm64-osx-out.log" \
        "$root/buildtrees/cpprestsdk/config-arm64-osx-rel-CMakeCache.txt.log" \
        "$root/buildtrees/cpprestsdk/config-arm64-osx-rel-CMakeConfigureLog.yaml.log" \
        "$root/buildtrees/cpprestsdk/config-x64-osx-out.log" \
        "$root/buildtrees/cpprestsdk/config-x64-osx-rel-CMakeCache.txt.log" \
        "$root/buildtrees/cpprestsdk/config-x64-osx-rel-CMakeConfigureLog.yaml.log"
    do
        if [ -f "$log" ]; then
            echo ""
            echo "── $(basename "$log") ──"
            tail -n 80 "$log" || true
        fi
    done
}

build_libwally() {
    local libwally_dir="${BUILD_ROOT}/libwally-core"
    local arch_flags="-arch ${BUILD_CMAKE_OSX_ARCH} -isysroot ${SDK_PATH_RESOLVED} -mmacosx-version-min=11.3"

    step "5/6" "Building libwally-core into local prefix (${BUILD_ARCH})"
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
        env PATH="$SHIM_DIR:$PATH" LIBTOOL=glibtool LIBTOOLIZE=glibtoolize \
            CC=clang CXX=clang++ CFLAGS="$arch_flags" CXXFLAGS="$arch_flags" LDFLAGS="$arch_flags" \
            ./tools/autogen.sh
        env PATH="$SHIM_DIR:$PATH" LIBTOOL=glibtool LIBTOOLIZE=glibtoolize \
            CC=clang CXX=clang++ CFLAGS="$arch_flags" CXXFLAGS="$arch_flags" LDFLAGS="$arch_flags" \
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
    apply_local_desktop_patches "$desktop_dir"
    ok "Desktop source at $(cd "$desktop_dir" && git rev-parse --short HEAD)"

    info "Using SDK: $SDK_PATH_RESOLVED"
    info "Using Qt CMake path: $QT_INSTALL_CMAKE_PATH_RESOLVED"
    info "Using desktop arch: $BUILD_ARCH"
    info "Using vcpkg triplet: $BUILD_VCPKG_TRIPLET"

    export QT_INSTALL_CMAKE_PATH="$QT_INSTALL_CMAKE_PATH_RESOLVED"
    export QT_ROOT="$QT_ROOT_RESOLVED"
    export MACOSX_DEPLOYMENT_TARGET=11.3
    export CC=clang
    export CXX=clang++
    export CMAKE_BUILD_TYPE=Release
    export VCPKG_BUILD_TYPE=release
    export VCPKG_ROOT="${desktop_dir}/ci_tools_atomic_dex/vcpkg-repo"
    export VCPKG_DEFAULT_BINARY_CACHE="${BUILD_ROOT}/vcpkg-cache"
    export VCPKG_BINARY_SOURCES="default,readwrite"
    mkdir -p "$VCPKG_DEFAULT_BINARY_CACHE"
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
    if ! (
        cd "$desktop_dir"
        git checkout -- vcpkg.json
        "${VCPKG_ROOT}/vcpkg" install \
            --triplet "$BUILD_VCPKG_TRIPLET" \
            --overlay-ports "$desktop_dir/ci_tools_atomic_dex/vcpkg-custom-ports/ports" \
            --overlay-triplets "$desktop_dir/cmake"
    ); then
        show_vcpkg_failure_logs "$VCPKG_ROOT"
        die "vcpkg dependency installation failed"
    fi

    step "6c" "Configuring desktop build"
    rm -rf "$build_dir"
    cmake -S "$desktop_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH_RESOLVED" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.3 \
        -DCMAKE_OSX_ARCHITECTURES="$BUILD_CMAKE_OSX_ARCH" \
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
        stage_kdf_in_app_bundle "$app_found"
        rm -rf "$OUTPUT_DIR/$(basename "$app_found")"
        cp -R "$app_found" "$OUTPUT_DIR/"
        ok "App bundle → $OUTPUT_DIR/$(basename "$app_found")"

        # Run macdeployqt to bundle Qt frameworks into the .app
        local macdeployqt_bin="$QT_ROOT_RESOLVED/clang_64/bin/macdeployqt"
        if [ -x "$macdeployqt_bin" ]; then
            step "6f" "Bundling Qt frameworks (macdeployqt)"
            "$macdeployqt_bin" "$OUTPUT_DIR/$(basename "$app_found")" -no-strip 2>&1 | sed 's/^/    /' || warn "macdeployqt had warnings"
            ok "Qt frameworks bundled"
        else
            warn "macdeployqt not found at $macdeployqt_bin — skipping framework bundling"
        fi

        # Create DMG (brief pause to let macdeployqt settle)
        local app_name="$(basename "$app_found" .app)"
        local dmg_path="$OUTPUT_DIR/${app_name}.dmg"
        step "6g" "Creating DMG"
        sleep 3
        hdiutil create -volname "${APP_NAME:-Komodo Wallet}" \
            -srcfolder "$OUTPUT_DIR/$(basename "$app_found")" \
            -ov -format UDZO "$dmg_path" 2>&1 | sed 's/^/    /'
        ok "DMG → $dmg_path"
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

    if ! $FLAG_KDF_ONLY; then
        resolve_qt
    fi

    echo ""
    echo "  CPUs: ${BUILD_CPUS}  |  host: ${HOST_ARCH}  |  build: ${BUILD_ARCH}  |  KDF: ${KDF_COMMIT}  |  Desktop: ${DESKTOP_COMMIT}"
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
