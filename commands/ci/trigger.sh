#!/bin/bash
# ci trigger — fire a manual workflow run and poll until it lands
#
#   ./commands/ci/trigger.sh linux              # Linux only
#   ./commands/ci/trigger.sh linux wasm          # Linux + WASM
#   ./commands/ci/trigger.sh all                 # everything
#   ./commands/ci/trigger.sh linux --no-wait     # fire and return
#   ./commands/ci/trigger.sh --ref some-branch linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

REPO="Canada-eCoin/legacy-atomicdex-builder"
WORKFLOW="build.yml"
POLL_INTERVAL=15
WAIT=true
GH_REF="main"
PLATFORMS=()
VERBOSE=false

# ── Parse args ──────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref)      GH_REF="$2"; shift 2 ;;
        --no-wait)  WAIT=false; shift ;;
        --verbose)  VERBOSE=true; shift ;;
        -v)         VERBOSE=true; shift ;;
        linux|macos|windows|wasm|all)
            PLATFORMS+=("$1")
            shift
            ;;
        *)
            echo "Unknown arg: $1"
            echo "Usage: ci trigger [linux|macos|windows|wasm|all]... [--ref branch] [--no-wait]"
            exit 1
            ;;
    esac
done

if [ "${#PLATFORMS[@]}" -eq 0 ]; then
    echo "Usage: ci trigger [linux|macos|windows|wasm|all]... [--ref branch] [--no-wait]"
    echo ""
    echo "Examples:"
    echo "  ci trigger linux              # Linux only, wait for result"
    echo "  ci trigger linux wasm          # Linux + WASM, wait"
    echo "  ci trigger all                 # every platform"
    echo "  ci trigger linux --no-wait     # fire and forget"
    echo "  ci trigger --ref feat/wasm linux wasm"
    exit 1
fi

# ── Build workflow_dispatch inputs ──────────────────────────────
ALL_PLATFORMS=("linux" "macos" "windows" "wasm")

# Start all false
declare -A INPUTS
for p in "${ALL_PLATFORMS[@]}"; do INPUTS[$p]="false"; done

# Set requested ones true (and 'all' fans to all four)
for p in "${PLATFORMS[@]}"; do
    if [ "$p" = "all" ]; then
        for ap in "${ALL_PLATFORMS[@]}"; do INPUTS[$ap]="true"; done
    else
        INPUTS[$p]="true"
    fi
done

GH_INPUTS=()
for p in "${ALL_PLATFORMS[@]}"; do
    GH_INPUTS+=(-f "$p=${INPUTS[$p]}")
done

# ── Fire the workflow ───────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════╗"
echo "║  CI Trigger — $REPO                  ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  ref: %-46s ║\n" "$GH_REF"
for p in "${ALL_PLATFORMS[@]}"; do
    if [ "${INPUTS[$p]}" = "true" ]; then
        printf "║  %-7s ● enabled%-34s ║\n" "$p" ""
    else
        printf "║  %-7s ○ skipped%-34s ║\n" "$p" ""
    fi
done
echo "╚══════════════════════════════════════════════════════╝"
echo ""

gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$GH_REF" "${GH_INPUTS[@]}"

if ! $WAIT; then
    echo "Fired — not waiting. Check status: gh run list --repo $REPO --limit 3"
    exit 0
fi

# ── Find the new run ────────────────────────────────────────────
echo -n "Waiting for run to appear"
for i in $(seq 1 12); do
    sleep 2
    RUN_ID=$(gh run list --repo "$REPO" --workflow="$WORKFLOW" --limit 1 --json databaseId,status --jq '.[0].databaseId' 2>/dev/null || echo "")
    RUN_STATUS=$(gh run list --repo "$REPO" --workflow="$WORKFLOW" --limit 1 --json databaseId,status --jq '.[0].status' 2>/dev/null || echo "")
    if [ -n "$RUN_ID" ] && [ "$RUN_STATUS" = "in_progress" ] || [ "$RUN_STATUS" = "queued" ]; then
        echo ""
        break
    fi
    echo -n "."
done

if [ -z "$RUN_ID" ]; then
    echo ""
    echo "ERROR: Could not find run. Check: gh run list --repo $REPO --limit 5"
    exit 1
fi

echo "Run ID: $RUN_ID"
echo "URL:    https://github.com/$REPO/actions/runs/$RUN_ID"
echo ""

# ── Poll loop ───────────────────────────────────────────────────
PREV_LINES=0

poll_run() {
    local json status conclusion
    json=$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion,jobs 2>/dev/null)
    status=$(echo "$json" | jq -r '.status // "unknown"')
    conclusion=$(echo "$json" | jq -r '.conclusion // ""')

    # ── Build one-line per job summary ──────────────────────────
    local output=""
    output+="$(date '+%H:%M:%S')  status: ${status}"

    local jobs_count
    jobs_count=$(echo "$json" | jq '.jobs | length')
    for ((idx=0; idx<jobs_count; idx++)); do
        local jname jstatus jconclusion steps_done steps_total
        jname=$(echo "$json" | jq -r ".jobs[$idx].name")
        jstatus=$(echo "$json" | jq -r ".jobs[$idx].status")
        jconclusion=$(echo "$json" | jq -r ".jobs[$idx].conclusion")

        steps_total=$(echo "$json" | jq ".jobs[$idx].steps | length")
        steps_done=$(echo "$json" | jq "[.jobs[$idx].steps[] | select(.status == \"completed\")] | length")

        # Icon by conclusion, then by status
        local icon="·"
        case "$jconclusion" in
            success)   icon="✓" ;;
            failure)   icon="✗" ;;
            cancelled) icon="⊘" ;;
            skipped)   icon="−" ;;
            *) case "$jstatus" in
                   in_progress) icon="▶" ;;
                   queued)      icon="○" ;;
                   waiting)     icon="⏳" ;;
               esac ;;
        esac

        output+=$'\n'"  ${icon} ${jname}  [${steps_done}/${steps_total}]  ${jstatus}"
        if [ -n "$jconclusion" ] && [ "$jconclusion" != "null" ]; then
            output+="  → ${jconclusion}"
        fi
    done

    echo "$output"
    echo "$status $conclusion"
}

# Move cursor up $PREV_LINES lines (clear previous frame)
clear_frame() {
    if [ "$PREV_LINES" -gt 0 ]; then
        printf '\033[%dA' "$PREV_LINES"
        printf '\033[J'  # clear to end of screen
    fi
}

trap 'echo ""; echo "Polling stopped."' INT

while true; do
    # Poll — get the display lines + status line
    RAW=$(poll_run)
    # Split: last line is the status/conclusion pair, rest is display
    DISPLAY_LINES=$(echo "$RAW" | sed '$d')
    STATUS_LINE=$(echo "$RAW" | tail -1)
    read -r CURRENT_STATUS CURRENT_CONCLUSION <<< "$STATUS_LINE"

    clear_frame
    echo "$DISPLAY_LINES"
    LINES_NOW=$(echo "$DISPLAY_LINES" | wc -l | tr -d ' ')
    PREV_LINES=$LINES_NOW

    # Exit conditions
    if [ "$CURRENT_STATUS" = "completed" ]; then
        echo ""
        if [ "$CURRENT_CONCLUSION" = "success" ]; then
            echo "═══ All jobs passed ✓ ═══"
            exit 0
        else
            echo "═══ Run failed ✗ (conclusion: ${CURRENT_CONCLUSION}) ═══"
            echo ""
            echo "Details: https://github.com/$REPO/actions/runs/$RUN_ID"
            exit 1
        fi
    fi

    sleep "$POLL_INTERVAL"
done
