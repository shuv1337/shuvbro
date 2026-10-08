#!/usr/bin/env bash
# fm-sharkboard.sh - opt-in SHark bridge for this home's exported live-board model.
# Usage: fm-sharkboard.sh publish|answers|sync|serve
# Set FM_HOME explicitly and FM_SHARKBOARD_CONFIG to a private sharkctl config
# with board:read and board:write. No default notification credential is used.
# serve polls every 120 seconds; sync ingests answers before publishing.
# Publication is board-only (no push). State and receipts live in
# state/sharkboard; a lock serializes all publishers and answer consumers.
# A receipt left at applying after interruption requires operator reconciliation;
# it is never automatically replayed or acknowledged as successfully applied.
# No service installation, old-board retirement, or login is performed here.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-sharkboard.mjs" "$@"
