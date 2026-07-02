#!/bin/bash
# install — install built artifacts from output/ to system paths
# Usage: ./commands/install/command.sh [linux|windows] [--prefix ~/.local]
#   ./commands/install/command.sh linux
#   ./commands/install/command.sh linux --prefix /usr/local

set -euo pipefail

TARGET="${1:-linux}"
PREFIX="${2:-$HOME/.local}"
BIN_DIR="${PREFIX}/bin"
APPS_DIR="${PREFIX}/share/applications"
ICONS_DIR="${PREFIX}/share/icons/hicolor/256x256/apps"
OUTPUT_DIR="./output/${TARGET}"

# ── Resolve prefix ───────────────────────────────────────
if [[ "${2:-}" == "--prefix" ]] && [[ -n "${3:-}" ]]; then
    PREFIX="$3"
    BIN_DIR="${PREFIX}/bin"
    APPS_DIR="${PREFIX}/share/applications"
    ICONS_DIR="${PREFIX}/share/icons/hicolor/256x256/apps"
fi

# ── Check output exists ──────────────────────────────────
if [[ ! -f "${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage" ]]; then
    echo "ERROR: No AppImage found at ${OUTPUT_DIR}/"
    echo "Run ./commands/build/command.sh first."
    exit 1
fi

# ── Create directories ───────────────────────────────────
mkdir -p "${BIN_DIR}" "${APPS_DIR}" "${ICONS_DIR}"

# ── Install AppImage ─────────────────────────────────────
APPIMAGE_SRC="${OUTPUT_DIR}/komodo-wallet-desktop-x86_64.AppImage"
APPIMAGE_DST="${BIN_DIR}/community-exchange"
echo "→ Installing AppImage → ${APPIMAGE_DST}"
cp "${APPIMAGE_SRC}" "${APPIMAGE_DST}"
chmod +x "${APPIMAGE_DST}"

# ── Install KDF ──────────────────────────────────────────
KDF_DST="(not present in ${OUTPUT_DIR})"
if [[ -f "${OUTPUT_DIR}/kdf" ]]; then
    KDF_DST="${BIN_DIR}/kdf"
    echo "→ Installing KDF → ${KDF_DST}"
    cp "${OUTPUT_DIR}/kdf" "${KDF_DST}"
    chmod +x "${KDF_DST}"
fi

# ── Install .desktop file ────────────────────────────────
DESKTOP_FILE="${APPS_DIR}/community-exchange.desktop"
echo "→ Installing .desktop → ${DESKTOP_FILE}"
cat > "${DESKTOP_FILE}" << 'EOF'
[Desktop Entry]
Name=Community Exchange
Comment=Sovereign multi-coin DEX wallet
Exec=community-exchange
Icon=community-exchange
Terminal=false
Type=Application
Categories=Finance;Network;
Keywords=dex;wallet;crypto;atomic;swap;
EOF

# ── Check PATH ───────────────────────────────────────────
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    echo
    echo "⚠  ${BIN_DIR} is not in your PATH."
    echo "   Add this to your ~/.bashrc or ~/.profile:"
    echo "   export PATH=\"\${PATH}:${BIN_DIR}\""
fi

echo
echo "=== Done ==="
echo "  AppImage:  ${APPIMAGE_DST}"
echo "  KDF:       ${KDF_DST}"
echo "  .desktop:  ${DESKTOP_FILE}"
echo
echo "Run: community-exchange"
