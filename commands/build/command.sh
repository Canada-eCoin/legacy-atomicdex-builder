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

OUT="${PROJECT_DIR}/output/${PLATFORM}"
LOG="${PROJECT_DIR}/logs/${PLATFORM}"
mkdir -p "$OUT" "$LOG"

echo "=== ${MODE} | ${TARGET} | ${PLATFORM} ==="

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
        LOGFILE="${LOG}/wasm-build.log"
        echo ""
        echo "=== KDF → WebAssembly ==="
        CACHE_FLAGS=()
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
            CACHE_FLAGS=(--cache-from type=gha,scope=wasm-build --cache-to type=gha,scope=wasm-build,mode=max)
        fi
        docker buildx build --progress=plain \
            "${CACHE_FLAGS[@]}" \
            --build-arg "PLATFORM=${PLATFORM}" \
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

    LOGFILE="${LOG}/build.log"
    echo ""
    echo "=== Docker build --target ${DOCKER_TARGET} ==="
    CACHE_FLAGS=()
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        CACHE_FLAGS=(--cache-from type=gha,scope=linux-build --cache-to type=gha,scope=linux-build,mode=max)
    fi
    docker buildx build --progress=plain \
        "${CACHE_FLAGS[@]}" \
        --build-arg "PLATFORM=${PLATFORM}" \
        --target "$DOCKER_TARGET" \
        -f src/Dockerfile \
        -o "$OUT" \
        . 2>&1 | stdbuf -oL tee "$LOGFILE"

    summarize_errors "$LOGFILE"

    echo ""
    echo "=== DONE ==="
    ls -lh "$OUT/"
    [ -f "$OUT/komodo-wallet-desktop-x86_64.AppImage" ] && echo "Run: $OUT/komodo-wallet-desktop-x86_64.AppImage"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# Native path — platform-native scripts with flag translation
# ═══════════════════════════════════════════════════════════════
if [ "$MODE" = "native" ]; then
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
