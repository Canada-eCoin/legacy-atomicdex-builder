#!/bin/bash
# ============================================================================
# build-mac.sh — Native macOS build for legacy atomicdex
# ============================================================================
# Single source of truth for macOS builds. Runs natively on macOS —
# no Docker required. Builds KDF as universal binary (arm64 + x86_64)
# and optionally the desktop wallet as an unsigned .app bundle.
#
# Usage:
#   ./build-mac.sh                   # full build (KDF universal + desktop stub)
#   ./build-mac.sh --kdf-only        # KDF engine only (universal binary)
#   ./build-mac.sh --desktop-only    # desktop .app bundle (needs pre-built KDF)
#   ./build-mac.sh --yes             # skip all consent prompts
#   ./build-mac.sh --install-deps    # install missing deps without building
#   ./build-mac.sh --dry-run         # check deps and print plan, no build
#
# Output:
#   output/mac/kdf                   # universal binary (arm64 + x86_64)
#   output/mac/kdf.sha256
#
# Logs:
#   logs/mac/build.log               # full build output
#   logs/mac/installed.log           # packages installed and how to undo
#
# Requirements:
#   macOS 12.0+ (Monterey or later)
#   Xcode Command Line Tools (xcode-select --install)
#   Homebrew (https://brew.sh)
#
# Desktop wallet: native macOS build requires QT5, which is large (~2-3GB).
# The script will offer to install via Homebrew. The desktop build path
# is structural — it follows the same cmake + vcpkg pattern as Linux but
# targets macOS frameworks (Cocoa instead of X11, Apple Silicon native).
# ============================================================================

set -euo pipefail

# ── Globals ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
CONFIG_DIR="${PROJECT_DIR}/config"
SOURCES_JSON="${CONFIG_DIR}/sources.json"

FLAG_YES=false
FLAG_KDF_ONLY=false
FLAG_DESKTOP_ONLY=false
FLAG_DRY_RUN=false
FLAG_INSTALL_DEPS_ONLY=false

# ── ENV var overrides ─────────────────────────────────────────
# BUILD_YES=1 is equivalent to --yes flag
if [ "${BUILD_YES:-}" = "1" ]; then FLAG_YES=true; fi

BUILD_CPUS="${BUILD_CPUS:-}"

# Paths: ENV vars override hardcoded defaults
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}/mac"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}/mac"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/.build}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"

for arg in "$@"; do
    case "$arg" in
        --yes|-y)              FLAG_YES=true ;;
        --kdf-only)            FLAG_KDF_ONLY=true ;;
        --desktop-only)        FLAG_DESKTOP_ONLY=true ;;
        --dry-run)             FLAG_DRY_RUN=true ;;
        --install-deps)        FLAG_INSTALL_DEPS_ONLY=true ;;
        --help|-h)
            sed -n '2,30p' "$0" | grep -v '^#!/'
            exit 0
            ;;
    esac
done

# CPU count
if [ -z "${BUILD_CPUS:-}" ]; then
    TOTAL_CPUS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    BUILD_CPUS=$(( TOTAL_CPUS / 2 ))  # macOS: use half (Thermal pressure)
    [ "$BUILD_CPUS" -lt 1 ] && BUILD_CPUS=1
fi

# ── Read config (ENV vars override config files) ──────────────
# For each: ENV var > config file > hardcoded fallback
KDF_REPO="${KDF_REPO:-$(jq -r '.kdf.repo' "$SOURCES_JSON")}"
KDF_COMMIT="${KDF_COMMIT:-$(jq -r '.kdf.commit' "$SOURCES_JSON")}"
DESKTOP_REPO="${DESKTOP_REPO:-$(jq -r '.desktop.repo' "$SOURCES_JSON")}"
DESKTOP_COMMIT="${DESKTOP_COMMIT:-$(jq -r '.desktop.commit' "$SOURCES_JSON")}"
APP_NAME="${APP_NAME:-}"
APP_WEBSITE="${APP_WEBSITE:-}"
SEED_URL="${SEED_URL:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_DEVELOPER_ID="${APPLE_DEVELOPER_ID:-}"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$BUILD_DIR"
INSTALLED_LOG="${LOG_DIR}/installed.log"

# ── Colors ───────────────────────────────────────────────────
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREEN='\033[32m'
C_YELLOW='\033[33m'; C_RED='\033[31m'; C_CYAN='\033[36m'

step()  { echo -e "${C_BOLD}${C_CYAN}Step $1${C_RESET}: $2"; }
ok()    { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }
fail()  { echo -e "  ${C_RED}✗${C_RESET} $1"; }
info()  { echo -e "    $1"; }

exec > >(tee -a "${LOG_DIR}/build.log") 2>&1

# ═══════════════════════════════════════════════════════════════
# Platform detection
# ═══════════════════════════════════════════════════════════════

detect_platform() {
    local arch os_ver

    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo ""
        echo -e "${C_RED}╔══════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_RED}║  This script only runs on macOS.                        ║${C_RESET}"
        echo -e "${C_RED}║  Detected: $(uname -s)                                   ║${C_RESET}"
        echo -e "${C_RED}╚══════════════════════════════════════════════════════════╝${C_RESET}"
        exit 1
    fi

    arch=$(uname -m)
    os_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")

    step "0/6" "Platform: macOS ${os_ver} (${arch})"

    # Warn if building on Intel — Apple Silicon is preferred
    if [ "$arch" = "x86_64" ]; then
        warn "Building on Intel Mac. Universal binary will only have x86_64."
        warn "For arm64, build on Apple Silicon or cross-compile."
    fi
}

# ═══════════════════════════════════════════════════════════════
# Dependency checking
# ═══════════════════════════════════════════════════════════════

check_all_deps() {
    local total_missing=0

    echo ""
    echo -e "${C_BOLD}── Checking system dependencies ──${C_RESET}"
    echo ""

    # ── Xcode CLI tools ────────────────────────────────────
    echo -e "${C_BOLD}Xcode CLI Tools:${C_RESET}"
    if xcode-select -p &>/dev/null; then
        ok "Xcode CLI tools installed"
    else
        fail "Xcode CLI tools are not installed (needed for compilers + SDK)"
        suggest_install "Xcode CLI tools" "C/C++ compiler, SDK headers (~2.5GB)" \
            'xcode-select --install'
        ((total_missing++))
    fi

    # ── Homebrew ───────────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}Homebrew:${C_RESET}"
    if command -v brew &>/dev/null; then
        ok "Homebrew installed"
    else
        fail "Homebrew is not installed (needed for cmake, QT5, libs)"
        suggest_install "Homebrew" "Package manager for macOS" \
            '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        ((total_missing++))
    fi

    # ── Build tools ────────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}Build tools:${C_RESET}"
    check_cmd cmake  "cmake"           "build system (4.3+)"   || ((total_missing++))
    check_cmd ninja  "ninja"           "fast build"             || ((total_missing++))
    check_cmd jq     "jq"              "JSON parser"            || ((total_missing++))
    check_cmd git    "git"             "version control"        || ((total_missing++))
    check_cmd curl   "curl"            "downloads"              || ((total_missing++))

    # cmake version check
    if command -v cmake &>/dev/null; then
        local cmake_ver
        cmake_ver=$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
        if [ "$(printf '%s\n' "4.3" "$cmake_ver" | sort -V | head -1)" != "4.3" ]; then
            warn "cmake $cmake_ver is too old — 4.3+ recommended"
            suggest_install "cmake 4.3+" "vcpkg needs cmake 4.3+" 'brew install cmake'
        fi
    fi

    # ── Rust ────────────────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}Rust toolchain:${C_RESET}"
    check_cmd rustup "rustup"          "Rust toolchain manager" || ((total_missing++))
    check_cmd cargo  "cargo"           "Rust build system"      || ((total_missing++))

    if ! command -v rustup &>/dev/null; then
        suggest_install "rustup" "Rust toolchain (~1.5GB)" \
            'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source "$HOME/.cargo/env"'
    fi

    # ── Crypto libs ─────────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}Crypto & network:${C_RESET}"
    if [ -e /usr/local/opt/openssl@3/include/openssl/ssl.h ] || \
       [ -e /opt/homebrew/opt/openssl@3/include/openssl/ssl.h ]; then
        ok "openssl@3 — OpenSSL headers"
    else
        fail "openssl@3 is not installed — TLS/crypto support"
        echo -e "  ${C_YELLOW}→ Install:${C_RESET} brew install openssl@3"
        ((total_missing++))
    fi

    # ── Protobuf ────────────────────────────────────────────
    check_cmd protoc "protobuf"        "Protocol Buffers compiler" || ((total_missing++))

    # ── Desktop deps (only if building desktop) ─────────────
    if ! $FLAG_KDF_ONLY; then
        echo ""
        echo -e "${C_BOLD}Desktop wallet (QT5, ~2.5GB):${C_RESET}"
        if [ -e /usr/local/opt/qt@5/lib/cmake/Qt5/Qt5Config.cmake ] || \
           [ -e /opt/homebrew/opt/qt@5/lib/cmake/Qt5/Qt5Config.cmake ]; then
            ok "qt@5 — QT5 framework"
        else
            fail "qt@5 is not installed — QT5 framework (~2.1GB)"
            echo -e "  ${C_YELLOW}→ Install:${C_RESET} brew install qt@5"
            ((total_missing++))
        fi
        if [ -e /usr/local/opt/cpprestsdk/include/cpprest/http_client.h ] || \
           [ -e /opt/homebrew/opt/cpprestsdk/include/cpprest/http_client.h ]; then
            ok "cpprestsdk — C++ REST SDK"
        else
            fail "cpprestsdk is not installed — HTTP client library"
            echo -e "  ${C_YELLOW}→ Install:${C_RESET} brew install cpprestsdk"
            ((total_missing++))
        fi
        # libwally-core build deps (needs GNU libtool, not Apple's)
        check_cmd automake    "automake"    "autotools (libwally build)" || ((total_missing++))
        check_cmd glibtool    "libtool"     "GNU libtool (not Apple's)"  || ((total_missing++))
        check_cmd gsed        "gnu-sed"     "libwally autogen.sh"         || ((total_missing++))
    fi

    echo ""
    if [ "$total_missing" -gt 0 ]; then
        echo -e "${C_YELLOW}${total_missing} dependencies missing.${C_RESET}"
    else
        echo -e "${C_GREEN}All dependencies present.${C_RESET}"
    fi

    return $total_missing
}

suggest_install() {
    local pkg="$1"; local why="$2"; local cmd="$3"
    echo -e "  ${C_YELLOW}→ Install:${C_RESET} $cmd"
    echo -e "  ${C_YELLOW}  Why:${C_RESET} $why"
    echo -e "  ${C_YELLOW}  Size:${C_RESET} ${4:-}"
}

check_cmd() {
    local bin="$1"; local pkg="$2"; local why="$3"
    if [ -e "$bin" ] 2>/dev/null; then
        ok "$pkg — $why"; return 0
    elif command -v "$bin" &>/dev/null; then
        ok "$pkg — $why"; return 0
    fi
    fail "$pkg is not installed — $why"
    echo -e "  ${C_YELLOW}→ Install:${C_RESET} brew install $pkg"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Install deps with consent
# ═══════════════════════════════════════════════════════════════

install_missing_deps() {
    local missing_count="$1"
    if [ "$missing_count" -eq 0 ]; then return 0; fi

    local brew_pkgs="cmake ninja jq git curl protobuf openssl@3 rustup-init automake libtool gnu-sed"
    local qt_pkgs="qt@5 cpprestsdk"

    echo ""
    echo -e "${C_YELLOW}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_YELLOW}║  Homebrew will install these packages:                  ║${C_RESET}"
    echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "  brew install ${brew_pkgs}"
    if ! $FLAG_KDF_ONLY; then
        echo "  brew install ${qt_pkgs}"
        info "QT5 estimated: ~2.5GB (includes QtWebEngine with Chromium)"
    fi
    echo ""
    info "Total download: ~1.5-4GB depending on what's missing"

    if $FLAG_YES; then
        echo "  (--yes: installing automatically)"
    elif ! $FLAG_DRY_RUN; then
        echo -n "Install now? [Y/n] "
        read -r answer
        if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
            echo "Cannot build without these. Re-run with --install-deps to just install deps."
            return 1
        fi
    fi

    if $FLAG_DRY_RUN; then
        echo "  [DRY RUN] would install packages now"
        return 0
    fi

    for pkg in $brew_pkgs; do
        brew list "$pkg" &>/dev/null && info "$pkg already installed" || {
            info "Installing $pkg..."
            brew install "$pkg" || warn "Failed to install $pkg — continuing"
        }
    done

    if ! $FLAG_KDF_ONLY; then
        for pkg in $qt_pkgs; do
            brew list "$pkg" &>/dev/null && info "$pkg already installed" || {
                info "Installing $pkg..."
                brew install "$pkg" || warn "Failed to install $pkg — continuing"
            }
        done
    fi

    ok "Dependencies installed"

    # Undo note
    echo "# Packages installed by build-mac.sh on $(date -Iseconds)" >> "$INSTALLED_LOG"
    echo "# To undo: brew uninstall ${brew_pkgs} ${qt_pkgs}" >> "$INSTALLED_LOG"
}

# ═══════════════════════════════════════════════════════════════
# Build: KDF engine (universal binary)
# ═══════════════════════════════════════════════════════════════

build_kdf() {
    step "3/6" "Cloning KDF source (pinned commit ${KDF_COMMIT})..."
    local kdf_dir="${BUILD_DIR}/kdf"

    if [ -d "$kdf_dir/.git" ]; then
        (cd "$kdf_dir" && git fetch origin && git checkout "$KDF_COMMIT" && git submodule update --init --recursive)
    else
        rm -rf "$kdf_dir"
        info "Cloning KDF — large repo, years of history — grab a coffee"
        git clone "$KDF_REPO" "$kdf_dir"
        (cd "$kdf_dir" && git checkout "$KDF_COMMIT" && git submodule update --init --recursive)
    fi
    ok "KDF source at $(cd "$kdf_dir" && git rev-parse --short HEAD)"

    step "4/6" "Building KDF — arm64 target..."
    cd "$kdf_dir"
    rustup target add aarch64-apple-darwin 2>/dev/null || true

    export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"

    cargo build --release \
        --target aarch64-apple-darwin \
        -p mm2_bin_lib \
        -j "$BUILD_CPUS" 2>&1 | sed 's/^/  /'

    cp "target/aarch64-apple-darwin/release/kdf" "${OUTPUT_DIR}/kdf-arm64"
    ok "KDF arm64 built"

    # ── x86_64 target ──────────────────────────────────────
    info "Building KDF — x86_64 target..."
    rustup target add x86_64-apple-darwin 2>/dev/null || true

    cargo build --release \
        --target x86_64-apple-darwin \
        -p mm2_bin_lib \
        -j "$BUILD_CPUS" 2>&1 | sed 's/^/  /'

    cp "target/x86_64-apple-darwin/release/kdf" "${OUTPUT_DIR}/kdf-x86_64"
    ok "KDF x86_64 built"

    # ── Combine: universal binary ───────────────────────────
    step "4b" "Combining into universal binary..."
    lipo "${OUTPUT_DIR}/kdf-arm64" "${OUTPUT_DIR}/kdf-x86_64" \
        -create -output "${OUTPUT_DIR}/kdf" 2>/dev/null || {
        warn "lipo failed — using arm64 binary as fallback"
        cp "${OUTPUT_DIR}/kdf-arm64" "${OUTPUT_DIR}/kdf"
    }

    rm -f "${OUTPUT_DIR}/kdf-arm64" "${OUTPUT_DIR}/kdf-x86_64"

    sha256sum "${OUTPUT_DIR}/kdf" | cut -d" " -f1 > "${OUTPUT_DIR}/kdf.sha256"

    local size
    size=$(du -h "${OUTPUT_DIR}/kdf" | cut -f1)
    ok "KDF universal binary — ${size} → ${OUTPUT_DIR}/kdf"
    ok "SHA256: $(cat "${OUTPUT_DIR}/kdf.sha256")"

    cd "$SCRIPT_DIR"
}

# ═══════════════════════════════════════════════════════════════
# Build: Desktop wallet (macOS .app bundle) — structural skeleton
# ═══════════════════════════════════════════════════════════════

build_desktop() {
    step "5/6" "Cloning desktop source (pinned commit ${DESKTOP_COMMIT})..."
    local dtop_dir="${BUILD_DIR}/desktop"

    if [ -d "$dtop_dir/.git" ]; then
        (cd "$dtop_dir" && git fetch origin && git checkout "$DESKTOP_COMMIT" && git submodule update --init --recursive)
    else
        rm -rf "$dtop_dir"
        info "Cloning desktop — large repo, years of history — grab another coffee"
        git clone "$DESKTOP_REPO" "$dtop_dir"
        (cd "$dtop_dir" && git checkout "$DESKTOP_COMMIT" && git submodule update --init --recursive)
    fi
    ok "Desktop source at $(cd "$dtop_dir" && git rev-parse --short HEAD)"

    step "6/6" "Building desktop wallet (.app bundle)..."

    cd "$dtop_dir"

    # ── KDF ──────────────────────────────────────
    info "Setting up KDF..."
    if [ ! -f "${OUTPUT_DIR}/kdf" ]; then
        fail "KDF binary not found at ${OUTPUT_DIR}/kdf — run: ./build kdf"
        return 1
    fi
    mkdir -p assets/tools/kdf
    cp "${OUTPUT_DIR}/kdf" assets/tools/kdf/kdf
    sed -i '' '/FetchContent_Declare(kdf/,+1d' CMakeLists.txt 2>/dev/null || true
    sed -i '' 's/FetchContent_MakeAvailable(kdf /FetchContent_MakeAvailable(/' CMakeLists.txt 2>/dev/null || true
    sed -i '' '/configure_file(\${kdf_SOURCE_DIR}/d' CMakeLists.txt 2>/dev/null || true

    # ── libwally ───────────────────────────────────────────
    if [ ! -f /usr/local/lib/libwallycore.a ] && [ ! -f /opt/homebrew/lib/libwallycore.a ]; then
        info "Building libwally-core..."
        rm -rf /tmp/libwally-core
        git clone https://github.com/ElementsProject/libwally-core \
            --recurse-submodules -b release_0.9.2 /tmp/libwally-core
        cd /tmp/libwally-core
        export LIBTOOL=glibtool LIBTOOLIZE=glibtoolize
        ./tools/autogen.sh
        ./configure --disable-shared --disable-tests LIBTOOL=glibtool
        make -j"$BUILD_CPUS" install
        cd "$dtop_dir"
        ok "libwally installed"
    fi

    # ── vcpkg ──────────────────────────────────────────────
    info "Setting up vcpkg..."
    if [ ! -d ci_tools_atomic_dex/vcpkg-repo/vcpkg ]; then
        sed -i '' '/"cpprestsdk"/d' vcpkg.json 2>/dev/null || true
        sed -i '' '/"boost-/d' vcpkg.json 2>/dev/null || true
        cd ci_tools_atomic_dex/vcpkg-repo
        ./bootstrap-vcpkg.sh
        cd "$dtop_dir"
    fi
    export VCPKG_ROOT="${dtop_dir}/ci_tools_atomic_dex/vcpkg-repo"

    info "Installing vcpkg packages..."
    "${VCPKG_ROOT}/vcpkg" install --triplet arm64-osx 2>&1 | sed 's/^/  /'

    # ── Build ──────────────────────────────────────────────
    unset SOURCE_DATE_EPOCH
    mkdir -p ci_tools_atomic_dex/build-Release
    cd ci_tools_atomic_dex/build-Release

    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5 2>/dev/null || echo /usr/local/opt/qt@5)" \
        ../../ 2>&1 | sed 's/^/  /'

    cmake --build . --config Release -j"$BUILD_CPUS" 2>&1 | sed 's/^/  /'

    # macOS app bundle is created by cmake install
    local app_bundle
    app_bundle=$(find . -name "*.app" -maxdepth 3 2>/dev/null | head -1)

    if [ -n "$app_bundle" ]; then
        cp -R "$app_bundle" "${OUTPUT_DIR}/"
        ok ".app bundle → ${OUTPUT_DIR}/"
    else
        warn "No .app bundle found — may need manual packaging"
    fi

    cd "$SCRIPT_DIR"
}

# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║  Native macOS Build${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "  CPUs: ${BUILD_CPUS}  |  KDF: ${KDF_COMMIT}  |  Desktop: ${DESKTOP_COMMIT}"
    echo ""

    step "1/6" "Detecting platform..."
    detect_platform

    step "2/6" "Checking dependencies..."
    check_all_deps; local missing=$?
    if [ "$missing" -eq 0 ]; then
        echo ""
    else
        if $FLAG_INSTALL_DEPS_ONLY; then
            install_missing_deps "$missing"
            echo ""
            echo -e "${C_GREEN}Dependencies installed. Ready to build.${C_RESET}"
            exit 0
        fi
        install_missing_deps "$missing" || exit 1
    fi

    if $FLAG_INSTALL_DEPS_ONLY; then
        echo ""
        echo -e "${C_GREEN}Dependencies are already installed. Nothing to do.${C_RESET}"
        exit 0
    fi

    if $FLAG_DRY_RUN; then
        echo ""
        echo -e "${C_GREEN}[DRY RUN] Would build:${C_RESET}"
        $FLAG_KDF_ONLY && echo "  → KDF universal binary"
        $FLAG_DESKTOP_ONLY && echo "  → Desktop .app bundle"
        ! $FLAG_KDF_ONLY && ! $FLAG_DESKTOP_ONLY && echo "  → KDF universal + Desktop .app"
        echo ""
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
    ls -lh "${OUTPUT_DIR}/" 2>/dev/null || echo "  (empty)"
    echo ""
    echo "  To sign for distribution (optional):"
    echo "    codesign --deep --force --verify --verbose \\"
    echo "      --sign 'Developer ID Application: Your Name (TEAMID)' \\"
    echo "      ${OUTPUT_DIR}/*.app"
    echo "    xcrun notarytool submit ${OUTPUT_DIR}/*.dmg \\"
    echo "      --apple-id your@email.com --team-id TEAMID --wait"
    echo ""
}

main
