#!/bin/bash
# update — pull latest pipeline changes, report if rebuild needed
# Usage: ./commands/update/command.sh [--auto]

set -euo pipefail

AUTO="${1:-}"

# ── Stash check ──────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
    echo "⚠  Working tree dirty — local changes will be preserved"
fi

# ── Store current HEAD ───────────────────────────────────
BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "none")

# ── Pull ─────────────────────────────────────────────────
echo "→ Pulling latest..."
git pull --ff-only 2>/dev/null || {
    echo "⚠  git pull failed (no network, or repo not configured)"
    echo "   Skipping update. Source files unchanged."
    exit 0
}

AFTER=$(git rev-parse HEAD)

# ── No changes ───────────────────────────────────────────
if [[ "$BEFORE" == "$AFTER" ]]; then
    echo "✓ Already up to date. No rebuild needed."
    exit 0
fi

# ── Changed — diff what matters ──────────────────────────
echo
echo "→ Changes since last build:"
git diff --name-only "$BEFORE" "$AFTER" | while read f; do
    echo "   $f"
done

echo
echo "→ Files that trigger a rebuild:"
CHANGED_BUILD_FILES=$(git diff --name-only "$BEFORE" "$AFTER" -- \
    commands/build/command.sh \
    commands/install/command.sh \
    commands/update/command.sh \
    src/Dockerfile \
    src/Dockerfile.kdf-wasm \
    src/build-linux.sh \
    src/build-mac.sh \
    src/build-windows.ps1 \
    src/docker-build.sh \
    src/_build-lib.sh \
    config/ 2>/dev/null || true)

if [[ -n "$CHANGED_BUILD_FILES" ]]; then
    echo "$CHANGED_BUILD_FILES" | while read f; do
        echo "   ⚡ $f"
    done
    echo
    echo "⚠  Build files changed — rebuild required."
    if [[ "$AUTO" == "--auto" ]]; then
        echo "→ Auto-rebuilding..."
        exec ./commands/build/command.sh
    else
        echo "   Run: ./commands/build/command.sh"
    fi
else
    echo "   (no build inputs changed)"
    echo "✓ No rebuild needed."
fi
