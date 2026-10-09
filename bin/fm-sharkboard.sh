#!/usr/bin/env bash
# fm-sharkboard.sh - opt-in SHark bridge for this home's exported live-board model.
# Usage: fm-sharkboard.sh publish|answers|sync|serve|quarantines
#        fm-sharkboard.sh reconcile --key KEY --receipt EVENT --outcome recorded|not-recorded
# Set FM_HOME explicitly and FM_SHARKBOARD_CONFIG to a private sharkctl config
# with board:read and board:write. No default notification credential is used,
# and ambient HARK_TOKEN and HARK_API_URL are dropped so they cannot override that config.
# serve polls every 120 seconds; sync ingests answers before publishing.
# Publication is board-only (no push). State and receipts live in
# state/sharkboard; a lock serializes all publishers and answer consumers, and
# a lock (including its recovery mutex) whose owner process is gone is cleared
# on the next run. Unknown owners and recovery chains over eight levels need
# operator reconciliation; legacy ownerless lock.reap directories are not guessed.
# serve logs a failed tick and keeps polling. Pending asks recover their remote
# identity before answers are matched, so a lost response cannot skip an answer.
# An answer fm-board.sh refuses, one with unexpected provenance, and one to a
# changed or earlier question becomes a rejected receipt plus an inbox note
# naming the captain's choice, and is never acknowledged. A lock or snapshot
# failure in the intake records nothing and is retried on the next tick.
# Captain dismissals reach the lead and are acknowledged before a still-local
# question is reasserted. SHark Later snoozes are applied as dated holds with
# sharkboard:snooze provenance. A rejected snooze is durably cancelled and the
# still-local question reasserted; answers racing cancellation remain for intake.
# Text is fitted to SHark's field limits; a row SHark still refuses (for example
# a secret-looking value) is logged by key only and retried without blocking
# intake or other rows. Active work heartbeats every publish, and a retired ask
# whose answer has not been read stays until that answer reaches the lead.
# An uncertain intake (including repair_failed or an interrupted applying journal)
# quarantines that ask and replacement questions for the same local task.
# Publication, reset, retirement and answer replay stay blocked for that task;
# unrelated intake, publication and heartbeats continue. A durable local inbox
# alert retries on failure; successful alerts are not repeated. A crash between
# inbox delivery and receipt persistence can duplicate the alert, never the action.
# quarantines prints private JSON with the key, receipt, event and pending journals.
# The lead must inspect the original local intake records and current remote ask
# and establish whether the action was recorded before running reconcile with
# that exact key, receipt and outcome. This explicit command journals the outcome,
# alerts the local lead, cancels an open remote ask or acknowledges its terminal
# result, then releases the quarantine for the next ordinary publication. It never
# invokes answer intake. A failed reconciliation remains quarantined; repeat the
# same command to finish it. Already completed identical commands are idempotent.
# A changed remote ask identity refuses reconciliation instead of mutating it.
# Older applying receipts are scoped from their original answer page or encoded
# ask identity. Missing legacy identity or corrupt journal state still refuses
# operation until the original records can be recovered; no target is guessed.
# No service installation, old-board retirement, or login is performed here.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-sharkboard.mjs" "$@"
