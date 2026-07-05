#!/bin/bash
# ============================================================================
# build-mac.sh — macOS build dispatcher for legacy atomicdex
# ============================================================================
# Usage:
#   ./build-mac.sh                    # host default: Intel on x86_64, arm on arm64
#   ./build-mac.sh --arch intel       # force Intel/x86_64 mac build
#   ./build-mac.sh --arch arm         # force native arm64 mac build
#   ./build-mac.sh --intel            # shorthand for --arch intel
#   ./build-mac.sh --arm              # shorthand for --arch arm
#   ./build-mac.sh --help             # this help
#
# Any remaining flags are forwarded to the selected architecture script.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    sed -n '2,14p' "$0" | grep -v '^#!/'
}

normalize_arch() {
    case "$1" in
        intel|x86_64|x64) echo "intel" ;;
        arm|arm64|aarch64) echo "arm" ;;
        *) return 1 ;;
    esac
}

FORCED_ARCH=""
FORWARDED_ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)
            [ "$#" -ge 2 ] || { echo "ERROR: --arch requires a value (intel|arm)" >&2; exit 1; }
            FORCED_ARCH="$(normalize_arch "$2")" || { echo "ERROR: unknown mac arch: $2" >&2; exit 1; }
            shift 2
            continue
            ;;
        --arch=*)
            FORCED_ARCH="$(normalize_arch "${1#--arch=}")" || { echo "ERROR: unknown mac arch: ${1#--arch=}" >&2; exit 1; }
            shift
            continue
            ;;
        --intel)
            FORCED_ARCH="intel"
            shift
            continue
            ;;
        --arm)
            FORCED_ARCH="arm"
            shift
            continue
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            FORWARDED_ARGS+=("$1")
            shift
            continue
            ;;
    esac
done

if [ -n "$FORCED_ARCH" ]; then
    SELECTED_ARCH="$FORCED_ARCH"
else
    case "$(uname -m)" in
        arm64) SELECTED_ARCH="arm" ;;
        x86_64) SELECTED_ARCH="intel" ;;
        *) echo "ERROR: unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
    esac
fi

case "$SELECTED_ARCH" in
    intel)
        TARGET_SCRIPT="$SCRIPT_DIR/build-mac-intel.sh"
        ;;
    arm)
        TARGET_SCRIPT="$SCRIPT_DIR/build-mac-arm.sh"
        if [ -z "$FORCED_ARCH" ]; then
            echo "→ Apple Silicon host detected; defaulting to native arm64 mac build"
            echo "  Use --arch intel to run the better-validated Intel/x86_64 path instead."
        fi
        ;;
    *)
        echo "ERROR: internal arch selection failure: $SELECTED_ARCH" >&2
        exit 1
        ;;
esac

exec "$TARGET_SCRIPT" "${FORWARDED_ARGS[@]}"
