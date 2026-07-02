#!/bin/bash
# ============================================================================
# build-linux.sh — Native Linux build for legacy atomicdex
# ============================================================================
# Single source of truth for Linux builds. Runs on bare metal, in Docker,
# or from CI — same script, same output.
#
# Usage:
#   ./build-linux.sh                  # full build (KDF + desktop)
#   ./build-linux.sh --kdf-only       # KDF engine only
#   ./build-linux.sh --desktop-only   # desktop wallet only (needs pre-built KDF)
#   ./build-linux.sh --yes            # skip all consent prompts
#   ./build-linux.sh --install-deps   # install missing deps without building
#   ./build-linux.sh --dry-run        # check deps and print plan, no build
#
# Output:
#   output/linux/kdf                              # KDF binary (~65MB)
#   output/linux/kdf.sha256
#   output/linux/komodo-wallet-desktop-x86_64.AppImage  # desktop AppImage (~187MB)
#   output/linux/komodo-wallet-desktop.sha256
#
# Logs:
#   logs/linux/build.log           # full build output
#   logs/linux/installed.log       # packages installed and how to undo
# ============================================================================

set -euo pipefail

# ── Globals ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
source "${SCRIPT_DIR}/_build-lib.sh"
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
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}/linux"
LOG_DIR="${LOG_DIR:-${PROJECT_DIR}/logs}/linux"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/.build}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"

# ── Parse flags ──────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --yes|-y)              FLAG_YES=true ;;
        --kdf-only)            FLAG_KDF_ONLY=true ;;
        --desktop-only)        FLAG_DESKTOP_ONLY=true ;;
        --dry-run)             FLAG_DRY_RUN=true ;;
        --install-deps)        FLAG_INSTALL_DEPS_ONLY=true ;;
        --help|-h)
            sed -n '2,25p' "$0" | grep -v '^#!/'
            exit 0
            ;;
    esac
done

# CPU count: use explicit BUILD_CPUS, or auto-cap at 1/3 of available
if [ -z "${BUILD_CPUS:-}" ]; then
    TOTAL_CPUS=$(nproc 2>/dev/null || echo 4)
    BUILD_CPUS=$(( TOTAL_CPUS / 3 ))
    [ "$BUILD_CPUS" -lt 1 ] && BUILD_CPUS=1
fi

# ── Read config (ENV vars override config files) ──────────────
# For each: ENV var > config file > hardcoded fallback
KDF_REPO="${KDF_REPO:-$(jq -r '.kdf.repo' "$SOURCES_JSON")}"
KDF_COMMIT="${KDF_COMMIT:-$(jq -r '.kdf.commit' "$SOURCES_JSON")}"
DESKTOP_REPO="${DESKTOP_REPO:-$(jq -r '.desktop.repo' "$SOURCES_JSON")}"
DESKTOP_COMMIT="${DESKTOP_COMMIT:-$(jq -r '.desktop.commit' "$SOURCES_JSON")}"
# Populate shared library globals
read_sources

# ── Setup dirs ───────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$BUILD_DIR"
INSTALLED_LOG="${LOG_DIR}/installed.log"

# ── Colors ───────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_CYAN='\033[36m'

step()  { echo -e "${C_BOLD}${C_CYAN}Step $1${C_RESET}: ${2:-}"; }
ok()    { echo -e "  ${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo -e "  ${C_YELLOW}⚠${C_RESET} $1"; }
fail()  { echo -e "  ${C_RED}✗${C_RESET} $1"; }
info()  { echo -e "    $1"; }

# ── Log everything ───────────────────────────────────────────
exec > >(tee -a "${LOG_DIR}/build.log") 2>&1

# ═══════════════════════════════════════════════════════════════
# Platform detection
# ═══════════════════════════════════════════════════════════════

detect_platform() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO="$ID"
        DISTRO_VER="$VERSION_ID"
    elif [ -f /etc/debian_version ]; then
        DISTRO="debian"
        DISTRO_VER=$(cat /etc/debian_version)
    else
        DISTRO="unknown"
        DISTRO_VER="unknown"
    fi

    PKG_MGR=""
    PKG_INSTALL=""
    PKG_LIST=""

    # Docker runs as root — no sudo needed
    local SUDO="sudo"
    if [ "${EUID:-0}" -eq 0 ]; then
        SUDO=""
    fi

    case "$DISTRO" in
        ubuntu|debian|pop|linuxmint|elementary|zorin)
            PKG_MGR="apt"
            PKG_INSTALL="${SUDO} apt install -y"
            PKG_LIST="dpkg -l"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            PKG_MGR="dnf"
            PKG_INSTALL="${SUDO} dnf install -y"
            PKG_LIST="rpm -q"
            ;;
        arch|endeavouros|manjaro)
            PKG_MGR="pacman"
            PKG_INSTALL="${SUDO} pacman -S --noconfirm"
            PKG_LIST="pacman -Q"
            ;;
        opensuse*|suse)
            PKG_MGR="zypper"
            PKG_INSTALL="${SUDO} zypper install -y"
            PKG_LIST="rpm -q"
            ;;
        *)
            PKG_MGR="unknown"
            PKG_INSTALL="echo 'Please install manually:'"
            PKG_LIST="which"
            ;;
    esac

    step "0/7" "Platform: ${DISTRO} ${DISTRO_VER} (${PKG_MGR})"
}

# ═══════════════════════════════════════════════════════════════
# Dependency checking
# ═══════════════════════════════════════════════════════════════

# Track what we installed for undo instructions
INSTALLED_PACKAGES=()

check_cmd() {
    # check_cmd <binary> <package_name> <"why needed"> [<alternate_cmd>]
    local bin="$1"
    local pkg="$2"
    local why="$3"
    local alt="${4:-}"

    if command -v "$bin" &>/dev/null; then
        ok "$bin — $why"
        return 0
    fi

    if [ -n "$alt" ] && command -v "$alt" &>/dev/null; then
        ok "$alt (as $bin) — $why"
        return 0
    fi

    fail "$bin is not installed — $why"
    return 1
}

suggest_install() {
    local pkg="$1"
    local why="$2"
    local install_cmd="$3"

    echo -e "  ${C_YELLOW}→ Install:${C_RESET} $install_cmd"
    echo -e "  ${C_YELLOW}  Why:${C_RESET} $why"
}

install_pkg() {
    local pkg="$1"
    local install_cmd="$2"

    echo "→ Installing $pkg..."
    if $FLAG_DRY_RUN; then
        echo "  [DRY RUN] would run: $install_cmd"
        return 0
    fi

    if eval "$install_cmd"; then
        INSTALLED_PACKAGES+=("$pkg")
        ok "Installed $pkg"
        return 0
    else
        fail "Failed to install $pkg"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# Ensure commands needed by the script itself
# ═══════════════════════════════════════════════════════════════

ensure_bootstrap() {
    local missing=()
    for cmd in jq git curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        echo -e "${C_YELLOW}╔══════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_YELLOW}║  Bootstrap: these tools are needed to run the build:   ║${C_RESET}"
        echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════╝${C_RESET}"
        for m in "${missing[@]}"; do
            case "$m" in
                jq)   suggest_install "$m" "JSON parsing (reads config/sources.json)" "$PKG_INSTALL jq" ;;
                git)  suggest_install "$m" "clone source repos" "$PKG_INSTALL git" ;;
                curl) suggest_install "$m" "download toolchains and AppImage tools" "$PKG_INSTALL curl" ;;
            esac
        done

        if ! $FLAG_YES && ! $FLAG_DRY_RUN; then
            echo ""
            echo -n "Install these now? [Y/n] "
            read -r answer
            if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
                echo "Cannot continue without these tools. Exiting."
                exit 1
            fi
        fi

        if ! $FLAG_DRY_RUN; then
            for m in "${missing[@]}"; do
                install_pkg "$m" "$PKG_INSTALL $m" || exit 1
            done
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
# Build dependency check + consent
# ═══════════════════════════════════════════════════════════════

check_all_deps() {
    local total_missing=0

    echo ""
    echo -e "${C_BOLD}── Checking system dependencies ──${C_RESET}"
    echo ""

    # ── Base toolchain ──────────────────────────────────────
    echo -e "${C_BOLD}Base toolchain:${C_RESET}"
    check_cmd gcc     "build-essential" "C compiler (GCC)"              || ((total_missing++))
    check_cmd g++     "build-essential" "C++ compiler (G++)"            || ((total_missing++))
    check_cmd make    "build-essential" "GNU Make"                       || ((total_missing++))
    check_cmd cmake   "cmake"           "build system (4.3+ needed)"     || ((total_missing++))
    check_cmd pkg-config "pkg-config"   "library discovery"              || ((total_missing++))

    # ── Rust ────────────────────────────────────────────────
    echo ""
    echo -e "${C_BOLD}Rust toolchain:${C_RESET}"
    check_cmd rustup  "rustup"          "Rust toolchain manager"         || ((total_missing++))
    check_cmd cargo   "cargo"           "Rust build system"              || ((total_missing++))

    if command -v cargo &>/dev/null; then
        local rust_ver
        rust_ver=$(rustc --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        info "rustc $rust_ver"
    fi

    if ! command -v rustup &>/dev/null; then
        echo ""
        suggest_install "rustup" "Rust toolchain (needed for KDF engine)" \
            'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && source "$HOME/.cargo/env"'
    fi

    # ── Crypto + network libs ───────────────────────────────
    echo ""
    echo -e "${C_BOLD}Crypto & network:${C_RESET}"
    check_cmd /usr/include/openssl/ssl.h "libssl-dev" "OpenSSL headers (TLS/crypto)" || ((total_missing++))

    # ── Protobuf ────────────────────────────────────────────
    check_cmd protoc  "protobuf-compiler" "Protocol Buffers compiler"    || ((total_missing++))

    # Only check desktop deps if building desktop
    if ! $FLAG_KDF_ONLY; then
        echo ""
        echo -e "${C_BOLD}Desktop wallet (QT5):${C_RESET}"

        local qt_deps=(
            "qtbase5-dev:QT5 base libraries (~500MB)"
            "qtdeclarative5-dev:QML engine"
            "qtquickcontrols2-5-dev:QT Quick Controls 2"
            "qttools5-dev:QT tools (lrelease, etc.)"
            "qtwebengine5-dev:QT WebEngine (Chromium-based)"
            "libqt5svg5-dev:SVG icon support"
            "libqt5charts5-dev:QT Charts"
            "libcpprest-dev:C++ REST SDK (HTTP client)"
        )

        for dep in "${qt_deps[@]}"; do
            local pkg="${dep%%:*}"
            local why="${dep#*:}"
            check_cmd /usr/lib/x86_64-linux-gnu/cmake/${pkg%-dev}/${pkg%-dev}Config.cmake \
                "$pkg" "$why" 2>/dev/null || {
                # fallback: check with dpkg
                if dpkg -l "$pkg" &>/dev/null 2>&1; then
                    ok "$pkg — $why"
                else
                    fail "$pkg is not installed — $why"
                    ((total_missing++))
                fi
            }
        done

        # X11 / display deps
        local x11_deps=(
            "libxcb1-dev:X11 protocol C bindings"
            "libxcb-keysyms1-dev:X11 keysyms"
            "libxcb-render-util0-dev:X11 render utilities"
            "libxkbcommon-x11-0:XKB common"
            "libgl1-mesa-dev:OpenGL"
            "libfuse2:FUSE (AppImage runtime)"
        )
        for dep in "${x11_deps[@]}"; do
            local pkg="${dep%%:*}"
            local why="${dep#*:}"
            dpkg -l "$pkg" &>/dev/null 2>&1 && ok "$pkg — $why" || {
                fail "$pkg is not installed — $why"; ((total_missing++))
            }
        done

        # Extra desktop build deps
        # Modern systems only have python3; libwally configure needs bare 'python'.
        # PYTHON=python3 is set at build time, but having python-is-python3
        # (or a symlink) prevents this from being a silent trap.
        if ! command -v python &>/dev/null; then
            if command -v python3 &>/dev/null; then
                warn "'python' not found (only python3) — will set PYTHON=python3 at build time"
                warn "  Fix: sudo apt install python-is-python3  (creates python→python3 symlink)"
            else
                fail "python3 is not installed — Python 3 (build scripts)"
                ((total_missing++))
            fi
        else
            ok "python — Python (build scripts)"
        fi

        local extra_deps=(
            "autoconf:autotools (libwally build)"
            "automake:autotools (libwally build)"
            "libtool:autotools (libwally build)"
            "ninja-build:Ninja build system (fast cmake)"
            "wget:file download (cmake, AppImage tools)"
            "fuse:FUSE kernel module (AppImage)"
        )
        for dep in "${extra_deps[@]}"; do
            local pkg="${dep%%:*}"
            local why="${dep#*:}"
            command -v "${pkg%%-build}" &>/dev/null 2>&1 || \
            dpkg -l "$pkg" &>/dev/null 2>&1 && ok "$pkg — $why" || {
                fail "$pkg is not installed — $why"; ((total_missing++))
            }
        done
    fi

    # ── Summary ─────────────────────────────────────────────
    echo ""
    if [ "$total_missing" -gt 0 ]; then
        echo -e "${C_YELLOW}${total_missing} dependencies missing.${C_RESET}"
    else
        echo -e "${C_GREEN}All dependencies present.${C_RESET}"
    fi

    return $total_missing
}

# ═══════════════════════════════════════════════════════════════
# Install missing deps with consent
# ═══════════════════════════════════════════════════════════════

install_missing_deps() {
    local missing_count="$1"
    if [ "$missing_count" -eq 0 ]; then
        return 0
    fi

    # Docker runs as root — no sudo needed
    local SUDO="sudo"
    if [ "${EUID:-0}" -eq 0 ]; then
        SUDO=""
    fi

    # Build the install command based on detected package manager
    local cmd=""
    case "$PKG_MGR" in
        apt)
            cmd="${SUDO} apt update && ${SUDO} apt install -y \\
    build-essential cmake pkg-config libssl-dev protobuf-compiler \\
    git curl wget python3 jq \\
    qtbase5-dev qtdeclarative5-dev qtquickcontrols2-5-dev \\
    qttools5-dev qtwebengine5-dev libqt5svg5-dev libqt5charts5-dev \\
    libqt5waylandclient5-dev libcpprest-dev \\
    qml-module-qtquick-controls qml-module-qtquick-controls2 \\
    qml-module-qtquick-dialogs qml-module-qtquick-extras \\
    qml-module-qtquick-layouts qml-module-qtquick-shapes \\
    qml-module-qtcharts qml-module-qtgraphicaleffects \\
    qml-module-qtwebengine qml-module-qt-labs-platform \\
    qml-module-qt-labs-settings \\
    libxcb1-dev libxcb-keysyms1-dev libxcb-render-util0-dev \\
    libxkbcommon-x11-0 libgl1-mesa-dev libfuse2 \\
    autoconf automake libtool ninja-build fuse \\
    libxcb-icccm4 libxcb-image0 libxcb-xinerama0 \\
    libxcursor-dev libxcomposite-dev libxdamage-dev \\
    libxrandr-dev libxtst-dev libxss-dev libdbus-1-dev \\
    libevent-dev libfontconfig1-dev libudev-dev libpci-dev \\
    libnss3-dev libasound2-dev libegl1-mesa-dev libcap-dev \\
    libpulse-dev linux-libc-dev lsb-release nodejs \\
    software-properties-common unzip zip zstd"
            UNDO_CMD="${SUDO} apt remove --purge build-essential cmake pkg-config libssl-dev protobuf-compiler qtbase5-dev qtdeclarative5-dev qtquickcontrols2-5-dev qttools5-dev qtwebengine5-dev libqt5svg5-dev libqt5charts5-dev libcpprest-dev autoconf automake libtool ninja-build && ${SUDO} apt autoremove"
            ;;
        dnf)
            cmd="${SUDO} dnf groupinstall -y 'C Development Tools and Libraries' && ${SUDO} dnf install -y \\
    cmake pkgconfig openssl-devel protobuf-compiler \\
    git curl wget python3 jq \\
    qt5-qtbase-devel qt5-qtdeclarative-devel qt5-qtquickcontrols2-devel \\
    qt5-qttools-devel qt5-qtwebengine-devel qt5-qtsvg-devel qt5-qtcharts-devel \\
    libxcb-devel xcb-util-keysyms-devel xcb-util-renderutil-devel \\
    libxkbcommon-x11 mesa-libGL-devel fuse-libs \\
    autoconf automake libtool ninja-build fuse \\
    cpprest-devel"
            UNDO_CMD="${SUDO} dnf groupremove 'C Development Tools and Libraries' && ${SUDO} dnf remove cmake pkgconfig openssl-devel protobuf-compiler qt5-qtbase-devel qt5-qtdeclarative-devel qt5-qtquickcontrols2-devel qt5-qttools-devel qt5-qtwebengine-devel qt5-qtsvg-devel qt5-qtcharts-devel cpprest-devel autoconf automake libtool ninja-build"
            ;;
        pacman)
            cmd="${SUDO} pacman -S --noconfirm \\
    base-devel cmake pkg-config openssl protobuf \\
    git curl wget python jq \\
    qt5-base qt5-declarative qt5-quickcontrols2 qt5-tools qt5-webengine \\
    qt5-svg qt5-charts \\
    libxcb xcb-util-keysyms xcb-util-renderutil libxkbcommon-x11 \\
    mesa fuse2 autoconf automake libtool ninja fuse"
            UNDO_CMD="${SUDO} pacman -Rns base-devel cmake pkg-config openssl protobuf qt5-base qt5-declarative qt5-quickcontrols2 qt5-tools qt5-webengine qt5-svg qt5-charts autoconf automake libtool ninja"
            ;;
        *)
            echo "Unsupported package manager. Install these manually:"
            echo "  build-essential, cmake, pkg-config, libssl-dev, protobuf-compiler"
            echo "  git, curl, wget, python3, jq"
            echo "  qtbase5-dev, qtdeclarative5-dev, qtquickcontrols2-5-dev"
            echo "  qttools5-dev, qtwebengine5-dev, libqt5svg5-dev, libqt5charts5-dev"
            echo "  libcpprest-dev, libxcb1-dev, libgl1-mesa-dev, libfuse2"
            echo "  autoconf, automake, libtool, ninja-build, fuse"
            return 1
            ;;
    esac

    echo ""
    echo -e "${C_YELLOW}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_YELLOW}║  The following command will install missing packages:   ║${C_RESET}"
    echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}$cmd${C_RESET}"
    echo ""

    local size_est
    case "$PKG_MGR" in
        apt) size_est="~3.5GB (QT5 + WebEngine = ~2.1GB)" ;;
        dnf) size_est="~3GB" ;;
        pacman) size_est="~2.5GB" ;;
        *)   size_est="unknown" ;;
    esac
    info "Estimated disk: $size_est"

    if $FLAG_DRY_RUN; then
        echo "  [DRY RUN] would install packages now"
        return 0
    fi

    echo ""
    echo "  Installing..."
    eval "$cmd" || {
        fail "Package installation failed."
        echo ""
        echo "  You can install them manually. The command is printed above."
        return 1
    }

    ok "All packages installed."

    # record for undo
    echo "# Packages installed by build-linux.sh on $(date -Iseconds)" >> "$INSTALLED_LOG"
    echo "# To undo: $UNDO_CMD" >> "$INSTALLED_LOG"
    echo "" >> "$INSTALLED_LOG"
}

# ═══════════════════════════════════════════════════════════════
# Rust toolchain setup
# ═══════════════════════════════════════════════════════════════

ensure_rust_target() {
    local target="$1"
    if rustup target list --installed | grep -q "$target"; then
        ok "Rust target $target already installed"
    else
        step "prep" "Installing Rust target: $target"
        rustup target add "$target"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Source cloning
# ═══════════════════════════════════════════════════════════════

clone_sources() {
    local component="$1"
    local repo commit
    if [ "$component" = "kdf" ]; then
        repo="$KDF_REPO"; commit="$KDF_COMMIT"
    else
        repo="$DESKTOP_REPO"; commit="$DESKTOP_COMMIT"
    fi
    clone_source "$component" "$repo" "$commit"
}

# ═══════════════════════════════════════════════════════════════
# Apply patches
# ═══════════════════════════════════════════════════════════════

apply_patches() {
    apply_patches_to "${CONFIG_DIR}/patches" "${BUILD_DIR}/${1}"
}

# ═══════════════════════════════════════════════════════════════
# Branding injection
# ═══════════════════════════════════════════════════════════════





# ═══════════════════════════════════════════════════════════════
# Build: KDF engine
# ═══════════════════════════════════════════════════════════════

build_kdf() {
    step "3/7" "Cloning KDF source (pinned commit ${KDF_COMMIT})..."
    clone_sources kdf

    step "4/7" "Building KDF engine (Rust, ~10 min on 2 CPUs)..."
    apply_patches kdf

    local kdf_dir="${BUILD_DIR}/kdf"
    local target="x86_64-unknown-linux-gnu"
    ensure_rust_target "$target"

    cd "$kdf_dir"

    export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"

    cargo build --release \
        --target "$target" \
        -p mm2_bin_lib \
        -j "$BUILD_CPUS" 2>&1 | sed 's/^/  /'

    # Copy output
    cp "target/${target}/release/kdf" "${OUTPUT_DIR}/kdf"
    sha256sum "${OUTPUT_DIR}/kdf" | cut -d" " -f1 > "${OUTPUT_DIR}/kdf.sha256"

    local size
    size=$(du -h "${OUTPUT_DIR}/kdf" | cut -f1)
    ok "KDF built — ${size} → ${OUTPUT_DIR}/kdf"
    ok "SHA256: $(cat "${OUTPUT_DIR}/kdf.sha256")"

    cd "$SCRIPT_DIR"
}

# ═══════════════════════════════════════════════════════════════
# Build: Desktop wallet
# ═══════════════════════════════════════════════════════════════

build_desktop() {
    step "5/7" "Cloning desktop source (pinned commit ${DESKTOP_COMMIT})..."
    clone_sources desktop

    step "6/7" "Building desktop wallet (C++/QT5, ~60 min first build)..."
    apply_patches desktop

    local dtop_dir="${BUILD_DIR}/desktop"
    local cpus="$BUILD_CPUS"
    export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(cd "${BUILD_DIR}/kdf" 2>/dev/null && git log -1 --format=%ct || date +%s)}"

    cd "$dtop_dir"

    # ── KDF ──────────────────────────────────────
    stage_kdf "$dtop_dir" "${OUTPUT_DIR}/kdf" || return 1
    strip_kdf_fetchcontent "$dtop_dir"

    # ── Dependencies (shared with Docker path) ─────────────
    ensure_libwally
    ensure_cmake
    ensure_vcpkg "$dtop_dir"
    ensure_linuxdeployqt "$dtop_dir"
    fix_nss_symlinks
    fix_qtwebengine_rpath

    cd "$dtop_dir"  # ensure_* functions may have changed CWD
    # ── Build ──────────────────────────────────────────────
    step "7/7" "Compiling desktop (cmake + ninja, ${cpus} CPUs)..."
    unset SOURCE_DATE_EPOCH  # linuxdeployqt sets its own timestamps

    mkdir -p ci_tools_atomic_dex/build-Release
    cd ci_tools_atomic_dex/build-Release

    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD_LIBRARIES="-lssl -lcrypto" \
        ../../ 2>&1 | sed 's/^/  /'

    cmake --build . --config Release -j"$cpus" 2>&1 | sed 's/^/  /'

    stage_kdf_appdir "$dtop_dir"

    ninja install 2>&1 | sed 's/^/  /' || true

    # Copy AppImage to output (find it whatever the name)
    local appimage
    appimage=$(find . -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)
    if [ -n "$appimage" ] && [ -f "$appimage" ]; then
        cp "$appimage" "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage"
    else
        warn "No AppImage found — raw binary only"
    fi

    if [ -f bin/AntaraAtomicDexAppDir/usr/bin/komodo-wallet ]; then
        cp bin/AntaraAtomicDexAppDir/usr/bin/komodo-wallet "${OUTPUT_DIR}/komodo-wallet-desktop" 2>/dev/null || true
    fi

    sha256sum "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage" 2>/dev/null | \
        cut -d" " -f1 > "${OUTPUT_DIR}/komodo-wallet-desktop.sha256" || true

    local size
    size=$(du -h "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage" 2>/dev/null | cut -f1 || echo "unknown")
    ok "Desktop built — ${size} → ${OUTPUT_DIR}/"

    cd "$SCRIPT_DIR"
}

# ═══════════════════════════════════════════════════════════════
# Undo instructions
# ═══════════════════════════════════════════════════════════════

write_undo_instructions() {
    cat >> "$INSTALLED_LOG" << 'UNDO'
# ── To undo everything this script did ────────────────────────
# Remove build artifacts:
#   rm -rf output/linux/ .build/
#
# Remove logs:
#   rm -rf logs/linux/
#
# Remove system packages (apt example):
#   sudo apt remove --purge [packages listed above]
#   sudo apt autoremove
#
# Remove libwally:
#   sudo rm /usr/local/lib/libwallycore.* /usr/local/include/wally_*
#
# Remove cmake 4.3.3 (if we installed it):
#   sudo rm /usr/local/bin/cmake /usr/local/bin/ccmake /usr/local/bin/cmake-gui
#   sudo rm -rf /usr/local/share/cmake-4.3
UNDO
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║  AtomicDEX — Native Linux Build                        ║${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "  CPUs: ${BUILD_CPUS}  |  KDF: ${KDF_COMMIT}  |  Desktop: ${DESKTOP_COMMIT}"
    echo ""

    step "1/7" "Detecting platform..."
    detect_platform

    step "2/7" "Checking dependencies..."
    ensure_bootstrap

    # check_all_deps returns missing count (0 = all present)
    local missing=0
    check_all_deps || missing=$?

    if [ "$missing" -eq 0 ]; then
        echo ""
    elif $FLAG_INSTALL_DEPS_ONLY; then
        install_missing_deps "$missing"
        echo ""
        echo -e "${C_GREEN}Dependencies installed. Ready to build.${C_RESET}"
        exit 0
    elif $FLAG_YES; then
        install_missing_deps "$missing" || exit 1
    else
        # Dependencies missing, no auto-install flag — print instructions and exit
        echo ""
        echo -e "${C_RED}╔══════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_RED}║  CANNOT BUILD: ${missing} dependencies are missing.          ║${C_RESET}"
        echo -e "${C_RED}╚══════════════════════════════════════════════════════════╝${C_RESET}"
        echo ""
        echo -e "  ${C_BOLD}Option 1:${C_RESET} Install dependencies, then re-run the build:"
        echo "    ./build-linux.sh --install-deps"
        echo ""
        echo -e "  ${C_BOLD}Option 2:${C_RESET} Install + build in one shot (no prompts):"
        echo "    ./build-linux.sh --yes"
        echo ""
        echo -e "  ${C_BOLD}Option 3:${C_RESET} Install manually. The full command is printed above"
        echo "             in the dependency check output."
        echo ""
        exit 1
    fi

    if $FLAG_INSTALL_DEPS_ONLY; then
        echo ""
        echo -e "${C_GREEN}Dependencies are already installed. Nothing to do.${C_RESET}"
        exit 0
    fi

    if $FLAG_DRY_RUN; then
        echo ""
        echo -e "${C_GREEN}[DRY RUN] Would build:${C_RESET}"
        $FLAG_KDF_ONLY && echo "  → KDF engine only"
        $FLAG_DESKTOP_ONLY && echo "  → Desktop wallet only"
        ! $FLAG_KDF_ONLY && ! $FLAG_DESKTOP_ONLY && echo "  → KDF + Desktop wallet"
        echo ""
        exit 0
    fi

    # ── Build KDF ──────────────────────────────────────────
    if ! $FLAG_DESKTOP_ONLY; then
        build_kdf
    fi

    # ── Build Desktop ──────────────────────────────────────
    if ! $FLAG_KDF_ONLY; then
        build_desktop
    fi

    # ── Done ───────────────────────────────────────────────
    write_undo_instructions

    echo ""
    echo -e "${C_BOLD}${C_GREEN}╔══════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}║  BUILD COMPLETE                                        ║${C_RESET}"
    echo -e "${C_BOLD}${C_GREEN}╚══════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    echo "  Output: ${OUTPUT_DIR}/"
    ls -lh "${OUTPUT_DIR}/" 2>/dev/null || echo "  (empty)"
    echo ""
    echo "  Logs:   ${LOG_DIR}/"
    echo "  Undo:   ${INSTALLED_LOG}"
    echo ""
    echo "  Run the desktop wallet:"
    echo "    cd ${OUTPUT_DIR} && chmod +x *.AppImage && ./komodo-wallet-desktop-x86_64.AppImage"
    echo ""
}

main
