#!/bin/bash
# build — Sovereign DEX build
#
#   ./build                  everything, Docker if available, auto-detect platform
#   ./build kdf              KDF engine only
#   ./build desktop          desktop AppImage only (needs KDF from prior run)
#   ./build wasm             KDF → WebAssembly
#   ./build native           force native build (bare metal, needs QT5 ~3GB)
#   ./build native kdf       native KDF only
#   ./build native desktop   native desktop only
#   ./build clean            remove .build/, output/, and BuildKit cache
#   ./build clean --all      also clear Docker BuildKit cache
#
# Docker path uses the multi-stage Dockerfile with cache mounts.
# Native path uses src/build-linux.sh with full dep detection.
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
MODE="auto"      # auto | docker | native
TARGET="all"     # all | kdf | desktop | wasm | clean

case "${1:-}" in
    native)
        MODE="native"
        TARGET="${2:-all}"
        ;;
    clean)
        MODE="clean"
        TARGET="clean"
        ;;
    kdf|desktop|wasm)
        MODE="auto"
        TARGET="$1"
        ;;
    ""|all|auto)
        MODE="auto"
        TARGET="all"
        ;;
    *)
        echo "Usage: ./build [native|clean] [kdf|desktop|wasm]"
        echo "       ./build                    everything, auto-detect"
        echo "       ./build kdf                KDF only"
        echo "       ./build desktop            desktop only"
        echo "       ./build wasm               KDF → WebAssembly"
        echo "       ./build native             force native build"
        echo "       ./build clean              remove build artifacts"
        exit 1
        ;;
esac

# ── Clean target ─────────────────────────────────────────────
if [ "$MODE" = "clean" ]; then
    echo "=== clean ==="
    echo "Removing .build/ ..."
    rm -rf .build
    echo "Removing output/ ..."
    rm -rf output
    echo "Removing logs/ ..."
    rm -rf logs
    if [ "${2:-}" = "--all" ]; then
        echo "Clearing Docker BuildKit cache ..."
        docker buildx prune -f 2>/dev/null || true
    fi
    echo "=== clean done ==="
    exit 0
fi

# ── Auto-detect Docker ───────────────────────────────────────
if [ "$MODE" = "auto" ]; then
    if docker version &>/dev/null; then
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
        DOCKER_BUILDKIT=1 docker build --progress=plain \
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
    DOCKER_BUILDKIT=1 docker build --progress=plain \
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

    case "$TARGET" in
        all)     FLAGS="--yes" ;;
        kdf)     FLAGS="--yes --kdf-only" ;;
        desktop) FLAGS="--yes --desktop-only" ;;
        *)       echo "Unknown target: $TARGET"; exit 1 ;;
    esac

    echo ""
    "$SCRIPT" $FLAGS
    exit $?
fi
