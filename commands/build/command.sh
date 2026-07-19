#!/bin/bash
# build — Sovereign DEX build
#
#   ./build                         everything, Docker if available, auto-detect platform
#   ./build kdf                     KDF engine only
#   ./build desktop                 desktop artifact only (needs KDF from prior run)
#   ./build wasm                    KDF → WebAssembly
#   ./build native                  force native build
#   ./build native kdf              native KDF only
#   ./build native desktop          native desktop only
#   ./build --dry-run               native dry-run (forces native path)
#   ./build --install-deps          native dependency install only (forces native path)
#   ./build native desktop --dry-run
#   ./build clean                   remove .build/, output/, and logs/
#   ./build clean --all             also clear Docker BuildKit cache
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

# ── Parse args ───────────────────────────────────────────────
MODE="auto"      # auto | docker | native | clean
TARGET="all"     # all | kdf | desktop | wasm | clean
NATIVE_FLAGS=()
FORCE_NATIVE=false
CLEAN_ALL=false

usage() {
    echo "Usage: ./build [native|docker|clean] [all|kdf|desktop|wasm] [flags]"
    echo "       ./build                         everything, auto-detect"
    echo "       ./build kdf                     KDF only"
    echo "       ./build desktop                 desktop only"
    echo "       ./build wasm                    KDF → WebAssembly"
    echo "       ./build native                  force native build"
    echo "       ./build --dry-run               native dry-run"
    echo "       ./build --install-deps          native dep install"
    echo "       ./build --arch intel            native mac Intel/x86_64 path"
    echo "       ./build --arch arm              native mac arm64 path"
    echo "       ./build clean [--all]           remove build artifacts"
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
    if docker version &>/dev/null && ! $FORCE_NATIVE; then
        MODE="docker"
    elif [ -f "src/build-${PLATFORM}.sh" ]; then
        MODE="native"
    else
        echo "ERROR: No Docker and no native build script for ${PLATFORM}"
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
    errors=$(grep -c -i -E '(error:|ERROR|failed:|FAILED|✗|fatal:|undefined reference)' "$log" 2>/dev/null || echo 0)
    local warnings
    warnings=$(grep -c -i -E '(warning:|WARNING|⚠)' "$log" 2>/dev/null || echo 0)
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
# Native path — src/build-linux.sh with dep detection
# ═══════════════════════════════════════════════════════════════
if [ "$MODE" = "native" ]; then
    SCRIPT="src/build-${PLATFORM}.sh"
    if [ ! -f "$SCRIPT" ]; then
        echo "ERROR: No native build script for ${PLATFORM}: $SCRIPT"
        exit 1
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

    echo ""
    "$SCRIPT" "${FLAGS[@]}"
    exit $?
fi
