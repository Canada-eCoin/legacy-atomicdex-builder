#!/bin/bash
# build — Sovereign DEX build
#
#   ./commands/build/command.sh                         auto-detect: Docker on Linux, native on macOS/Windows
#   ./commands/build/command.sh kdf                     KDF engine only
#   ./commands/build/command.sh desktop                 desktop artifact only (needs KDF from prior run)
#   ./commands/build/command.sh wasm                    KDF → WebAssembly
#   ./commands/build/command.sh native                  force native build
#   ./commands/build/command.sh native kdf              native KDF only
#   ./commands/build/command.sh native desktop          native desktop only
#   ./commands/build/command.sh --dry-run               native dry-run (forces native path)
#   ./commands/build/command.sh --install-deps          native dependency install only (forces native path)
#   ./commands/build/command.sh native desktop --dry-run
#   ./commands/build/command.sh clean                   remove .build/, output/, and logs/
#   ./commands/build/command.sh clean --all             also clear Docker BuildKit cache
#
# Docker path uses the multi-stage Dockerfile with cache mounts.
# Native path forwards native flags to the platform build script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

# ── Detect platform ──────────────────────────────────────────
case "$(uname -s)" in
    Linux)  PLATFORM="linux" ;;
    Darwin) PLATFORM="mac" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
    *)      echo "Unknown platform: $(uname -s)"; exit 1 ;;
esac

native_script_for_platform() {
    case "$1" in
        windows) echo "src/build-windows.ps1" ;;
        linux|mac) echo "src/build-$1.sh" ;;
        *) return 1 ;;
    esac
}

windows_powershell_runner() {
    if command -v pwsh >/dev/null 2>&1; then
        echo "pwsh"
    elif command -v powershell.exe >/dev/null 2>&1; then
        echo "powershell.exe"
    elif command -v powershell >/dev/null 2>&1; then
        echo "powershell"
    else
        return 1
    fi
}

read_linux_builder_bases() {
    local toolchains_json="${PROJECT_DIR}/config/toolchains.json"
    if [ ! -f "$toolchains_json" ]; then
        echo "ERROR: Missing config/toolchains.json" >&2
        exit 1
    fi
    KDF_BASE_IMAGE="${KDF_BASE_IMAGE:-$(jq -r '.builder_bases.linux_kdf.source + ":" + .builder_bases.linux_kdf.tag' "$toolchains_json")}"
    DESKTOP_BASE_IMAGE="${DESKTOP_BASE_IMAGE:-$(jq -r '.builder_bases.linux_desktop.source + ":" + .builder_bases.linux_desktop.tag' "$toolchains_json")}"
}

read_wasm_builder_base() {
    local sources_json="${PROJECT_DIR}/config/sources.json"
    local toolchains_json="${PROJECT_DIR}/config/toolchains.json"
    if [ ! -f "$sources_json" ]; then
        echo "ERROR: Missing config/sources.json" >&2
        exit 1
    fi
    if [ ! -f "$toolchains_json" ]; then
        echo "ERROR: Missing config/toolchains.json" >&2
        exit 1
    fi
    WASM_KDF_BASE_IMAGE="${WASM_KDF_BASE_IMAGE:-$(jq -r '.builder_bases.wasm_kdf.source + ":" + .builder_bases.wasm_kdf.tag' "$toolchains_json")}"
    BINARYEN_REPO="${BINARYEN_REPO:-$(jq -r '.dependencies.binaryen.repo' "$sources_json")}"
    BINARYEN_TAG="${BINARYEN_TAG:-$(jq -r '.dependencies.binaryen.tag' "$sources_json")}"
}

# ── Parse args ───────────────────────────────────────────────
MODE="auto"      # auto | docker | native | clean
TARGET="all"     # all | kdf | desktop | wasm | clean
NATIVE_FLAGS=()
FORCE_NATIVE=false
CLEAN_ALL=false

usage() {
    echo "Usage: ./commands/build/command.sh [native|docker|clean] [all|kdf|desktop|wasm] [flags]"
    echo "       ./commands/build/command.sh                         auto-detect (Docker on Linux, native elsewhere)"
    echo "       ./commands/build/command.sh kdf                     KDF only"
    echo "       ./commands/build/command.sh desktop                 desktop only"
    echo "       ./commands/build/command.sh wasm                    KDF → WebAssembly"
    echo "       ./commands/build/command.sh native                  force native build"
    echo "       ./commands/build/command.sh --dry-run               native dry-run"
    echo "       ./commands/build/command.sh --install-deps          native dep install"
    echo "       ./commands/build/command.sh --arch intel            native mac Intel/x86_64 path"
    echo "       ./commands/build/command.sh --arch arm              native mac arm64 path"
    echo "       ./commands/build/command.sh clean [--all]           remove build artifacts"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        native|docker|auto)
            MODE="$1"
            ;;
        clean)
            MODE="clean"
            TARGET="clean"
            ;;
        all|kdf|desktop|wasm)
            TARGET="$1"
            ;;
        --kdf-only)
            TARGET="kdf"
            FORCE_NATIVE=true
            ;;
        --desktop-only)
            TARGET="desktop"
            FORCE_NATIVE=true
            ;;
        --yes|-y|--dry-run|--install-deps|--intel|--arm|--arch=*)
            NATIVE_FLAGS+=("$1")
            FORCE_NATIVE=true
            ;;
        --arch)
            if [ "$#" -lt 2 ]; then
                echo "ERROR: --arch requires a value (intel|arm)"
                exit 1
            fi
            NATIVE_FLAGS+=("$1" "$2")
            FORCE_NATIVE=true
            shift
            ;;
        --all)
            CLEAN_ALL=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            echo ""
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
    shift
done

if [ "$MODE" = "clean" ] && [ "$TARGET" != "clean" ]; then
    echo "ERROR: clean mode does not take a build target"
    exit 1
fi

if $FORCE_NATIVE && [ "$MODE" = "auto" ]; then
    MODE="native"
fi

if [ "$TARGET" = "wasm" ] && [ "$MODE" = "native" ]; then
    echo "ERROR: wasm target is Docker-only"
    exit 1
fi

if [ "$MODE" = "docker" ] && [ "${#NATIVE_FLAGS[@]}" -gt 0 ]; then
    echo "ERROR: --yes, --dry-run, --install-deps, and mac arch flags are native-only flags"
    exit 1
fi

# ── Clean target ─────────────────────────────────────────────
if [ "$MODE" = "clean" ]; then
    echo "=== clean ==="
    echo "Removing .build/ ..."
    rm -rf .build
    echo "Removing output/ ..."
    rm -rf output
    echo "Removing logs/ ..."
    rm -rf logs
    if $CLEAN_ALL; then
        echo "Clearing Docker BuildKit cache ..."
        docker buildx prune -f 2>/dev/null || true
    fi
    echo "=== clean done ==="
    exit 0
fi

# ── Auto-detect Docker ───────────────────────────────────────
if [ "$MODE" = "auto" ]; then
    NATIVE_SCRIPT="$(native_script_for_platform "$PLATFORM")"
    if [ "$TARGET" = "wasm" ]; then
        if docker version &>/dev/null; then
            MODE="docker"
        else
            echo "ERROR: wasm target requires Docker"
            exit 1
        fi
    elif [ "$PLATFORM" = "linux" ] && docker version &>/dev/null && ! $FORCE_NATIVE; then
        MODE="docker"
    elif [ -f "$NATIVE_SCRIPT" ]; then
        MODE="native"
    elif docker version &>/dev/null; then
        MODE="docker"
    else
        echo "ERROR: No native build script for ${PLATFORM} and Docker unavailable"
        exit 1
    fi
fi

# Resolve actual output directory (macOS adds arch suffix)
_resolve_platform_dir() {
    local suffix="$PLATFORM"
    if [ "$PLATFORM" = "mac" ]; then
        suffix="mac-intel"  # default
        local i
        for ((i=0; i<${#NATIVE_FLAGS[@]}; i++)); do
            case "${NATIVE_FLAGS[$i]}" in
                --arch=arm|--arm)   suffix="mac-arm"; break ;;
                --arch=intel|--intel) suffix="mac-intel"; break ;;
                --arch)
                    local next="${NATIVE_FLAGS[$i+1]:-}"
                    [ "$next" = "arm" ] && suffix="mac-arm"
                    break ;;
            esac
        done
    fi
    echo "$suffix"
}
PLATFORM_DIR="$(_resolve_platform_dir)"
OUT="${PROJECT_DIR}/output/${PLATFORM_DIR}"
LOG="${PROJECT_DIR}/logs/${PLATFORM_DIR}"
mkdir -p "$OUT" "$LOG"

echo "=== ${MODE} | ${TARGET} | ${PLATFORM} ==="

# ── Cache-hit fast path ─────────────────────────────────────
# Expected output artifacts per platform. If they all exist,
# the build is skipped — the CI cache already has them.
_check_cache_hit() {
    local out_dir="$1" target="$2"
    local dir_name="$(basename "$out_dir")"

    # WASM target checks its own output files
    case "$target" in
        wasm)
            [ -f "$out_dir/mm2_bg.wasm" ] && [ -f "$out_dir/mm2.js" ] || return 1
            return 0 ;;
    esac

    case "$target" in
        all|kdf)
            case "$dir_name" in
                linux)   [ -f "$out_dir/atomicdex-kdf-linux-x86_64" ]           || return 1 ;;
                mac-intel) [ -f "$out_dir/atomicdex-kdf-macos-intel" ]         || return 1 ;;
                mac-arm)   [ -f "$out_dir/atomicdex-kdf-macos-arm" ]           || return 1 ;;
                windows)   [ -f "$out_dir/atomicdex-kdf-windows-x86_64.exe" ]  || return 1 ;;
                *)         return 1 ;;  # unknown platform — don't skip
            esac ;;
    esac
    case "$target" in
        all|desktop)
            case "$dir_name" in
                linux)   [ -f "$out_dir/atomicdex-desktop-linux-x86_64.AppImage" ]  || return 1 ;;
                mac-intel) [ -f "$out_dir/atomicdex-desktop-macos-intel.dmg" ]      || return 1 ;;
                mac-arm)   [ -f "$out_dir/atomicdex-desktop-macos-arm.dmg" ]        || return 1 ;;
                windows)   [ -f "$out_dir/atomicdex-desktop-windows-x86_64-portable.zip" ] || return 1 ;;
                *)         return 1 ;;  # unknown platform — don't skip
            esac ;;
    esac
    return 0
}

_maybe_skip_cache_hit() {
    if [ "${BUILD_YES:-}" != "force" ] && _check_cache_hit "$OUT" "$TARGET"; then
        echo ""
        echo "═══ Cache hit — outputs already built, skipping ═══"
        ls -lh "$OUT/" 2>/dev/null || true
        echo ""
        exit 0
    fi
}

# ── Error summary helper ─────────────────────────────────────
summarize_errors() {
    local log="$1"
    if [ ! -f "$log" ]; then return; fi
    local errors
    errors=$(grep -c -i -E '(error:|ERROR|failed:|FAILED|✗|fatal:|undefined reference)' "$log" 2>/dev/null || true)
    errors=${errors:-0}
    local warnings
    warnings=$(grep -c -i -E '(warning:|WARNING|⚠)' "$log" 2>/dev/null || true)
    warnings=${warnings:-0}
    if [ "$errors" -gt 0 ] || [ "$warnings" -gt 0 ]; then
        echo ""
        echo "── Build Summary ──────────────────────────"
        echo "  errors:   ${errors}"
        echo "  warnings: ${warnings}"
        if [ "$errors" -gt 0 ]; then
            echo ""
            echo "  Last 5 errors:"
            grep -i -E '(error:|ERROR|failed:|FAILED|✗|fatal:|undefined reference)' "$log" | tail -5 | sed 's/^/    /'
        fi
        echo "  Full log: ${log}"
        echo "────────────────────────────────────────────"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Docker path — multi-stage Dockerfile with --target
# ═══════════════════════════════════════════════════════════════
if [ "$MODE" = "docker" ]; then
    # WASM uses its own Dockerfile (different base image concerns)
    if [ "$TARGET" = "wasm" ]; then
        OUT="${PROJECT_DIR}/output/wasm"
        LOG="${PROJECT_DIR}/logs/wasm"
        mkdir -p "$OUT" "$LOG"
        _maybe_skip_cache_hit
        LOGFILE="${LOG}/wasm-build.log"
        echo ""
        echo "=== KDF → WebAssembly ==="
        CACHE_FLAGS=()
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
            CACHE_FLAGS=(--cache-from type=gha,scope=wasm-build --cache-to type=gha,scope=wasm-build,mode=min)
        fi
        read_wasm_builder_base
        docker buildx build --progress=plain \
            "${CACHE_FLAGS[@]}" \
            --build-arg "PLATFORM=${PLATFORM}" \
            --build-arg "WASM_KDF_BASE_IMAGE=${WASM_KDF_BASE_IMAGE}" \
            --build-arg "BINARYEN_REPO=${BINARYEN_REPO}" \
            --build-arg "BINARYEN_TAG=${BINARYEN_TAG}" \
            -f src/Dockerfile.kdf-wasm \
            -o "$OUT" \
            . 2>&1 | stdbuf -oL tee "$LOGFILE"
        summarize_errors "$LOGFILE"
        echo ""
        echo "=== DONE ==="
        ls -lh "$OUT/"
        exit 0
    fi

    # Map target → Docker --target stage
    case "$TARGET" in
        all)     DOCKER_TARGET="all" ;;
        kdf)     DOCKER_TARGET="kdf" ;;
        desktop) DOCKER_TARGET="desktop" ;;
    esac

    _maybe_skip_cache_hit

    LOGFILE="${LOG}/build.log"
    echo ""
    echo "=== Docker build --target ${DOCKER_TARGET} ==="
    CACHE_FLAGS=()
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        CACHE_FLAGS=(--cache-from type=gha,scope=linux-build --cache-to type=gha,scope=linux-build,mode=min)
    fi
    read_linux_builder_bases
    docker buildx build --progress=plain \
        "${CACHE_FLAGS[@]}" \
        --build-arg "PLATFORM=${PLATFORM}" \
        --build-arg "KDF_BASE_IMAGE=${KDF_BASE_IMAGE}" \
        --build-arg "DESKTOP_BASE_IMAGE=${DESKTOP_BASE_IMAGE}" \
        --target "$DOCKER_TARGET" \
        -f src/Dockerfile \
        -o "$OUT" \
        . 2>&1 | stdbuf -oL tee "$LOGFILE"

    summarize_errors "$LOGFILE"

    echo ""
    echo "=== DONE ==="
    ls -lh "$OUT/"
    [ -f "$OUT/atomicdex-desktop-linux-x86_64.AppImage" ] && echo "Run: $OUT/atomicdex-desktop-linux-x86_64.AppImage"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# Native path — platform-native scripts with flag translation
# ═══════════════════════════════════════════════════════════════
if [ "$MODE" = "native" ]; then
    _maybe_skip_cache_hit

    SCRIPT="$(native_script_for_platform "$PLATFORM")"
    if [ ! -f "$SCRIPT" ]; then
        echo "ERROR: No native build script for ${PLATFORM}: $SCRIPT"
        exit 1
    fi

    echo ""

    if [ "$PLATFORM" = "windows" ]; then
        RUNNER="$(windows_powershell_runner)" || {
            echo "ERROR: Windows native build requires PowerShell (pwsh or powershell.exe)"
            exit 1
        }

        FLAGS=("-Yes")
        case "$TARGET" in
            all)     ;;
            kdf)     FLAGS+=("-KdfOnly") ;;
            desktop) FLAGS+=("-DesktopOnly") ;;
            *)       echo "Unknown target for native build: $TARGET"; exit 1 ;;
        esac

        for flag in "${NATIVE_FLAGS[@]}"; do
            case "$flag" in
                --yes|-y)          ;;
                --dry-run)         FLAGS+=("-DryRun") ;;
                --install-deps)    FLAGS+=("-InstallDeps") ;;
                --intel|--arm|--arch|--arch=*)
                    echo "ERROR: ${flag} is a mac-only flag and is not valid for Windows builds"
                    exit 1
                    ;;
                *)
                    echo "ERROR: Unsupported Windows native flag: ${flag}"
                    exit 1
                    ;;
            esac
        done

        "$RUNNER" -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT" "${FLAGS[@]}"
        exit $?
    fi

    FLAGS=("--yes")
    case "$TARGET" in
        all)     ;;
        kdf)     FLAGS+=("--kdf-only") ;;
        desktop) FLAGS+=("--desktop-only") ;;
        *)       echo "Unknown target for native build: $TARGET"; exit 1 ;;
    esac

    if [ "${#NATIVE_FLAGS[@]}" -gt 0 ]; then
        FLAGS+=("${NATIVE_FLAGS[@]}")
    fi

    "$SCRIPT" "${FLAGS[@]}"
    exit $?
fi
