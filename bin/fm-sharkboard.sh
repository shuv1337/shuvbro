#!/usr/bin/env bash
# fm-sharkboard.sh - opt-in SHark bridge for this home's exported live-board model.
# Usage: fm-sharkboard.sh publish|answers|sync|serve
# Set FM_HOME explicitly and FM_SHARKBOARD_CONFIG to a private sharkctl config
# with board:read and board:write. No default notification credential is used.
# serve polls every 120 seconds; sync ingests answers before publishing.
# Publication is board-only (no push). State and receipts live in
# state/sharkboard; a lock serializes all publishers and answer consumers, and
# a lock whose owner process is gone is cleared on the next run.
# serve logs a failed tick and keeps polling. Pending asks recover their remote
# identity before answers are matched, so a lost response cannot skip an answer.
# An answer fm-board.sh refuses, one with unexpected provenance, and one to a
# changed or earlier question becomes a rejected receipt plus an inbox note
# naming the captain's choice, and is never acknowledged. A lock or snapshot
# failure in the intake records nothing and is retried on the next tick.
# SHark Later snoozes are applied as dated holds with sharkboard:snooze provenance.
# Text is fitted to SHark's field limits; a row SHark still refuses (for example
# a secret-looking value) is logged by key only and retried without blocking
# intake or other rows. Active work heartbeats every publish, and a retired ask
# whose answer has not been read stays until that answer reaches the lead.
# A receipt left at applying after interruption requires operator reconciliation;
# it is never automatically replayed or acknowledged as successfully applied.
# No service installation, old-board retirement, or login is performed here.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-sharkboard.mjs" "$@"
