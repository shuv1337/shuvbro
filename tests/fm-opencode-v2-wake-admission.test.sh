#!/usr/bin/env bash
# Wake handoff and admission sequencing for the OpenCode V2 adapter, against the
# real recovery helpers.
#
# Part 1 pins the helper contract the adapter must respect: the handling
# handoff (`fm-watch-arm.sh --handling-delivered`) is accepted while the
# episode is still open, and rejected once the lead has drained and
# acknowledged it. A confirmation issued after prompt admission therefore races
# the lead's own acknowledgement, most visibly when an admission acknowledgement
# is lost and retried after backoff.
#
# The adapter-level admission outcomes (one admitted logical wake across
# rejected admissions and lost receipts, durable rows kept until the lead
# acknowledges, no stranded wake after an outage, owner retirement) run against
# the native TUI entry in tests/fm-opencode-v2-tui-acceptance.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# Fixture boundary: no ambient native session identity or activation, and a
# token-only registry namespace for any production helper this run reaches.
unset OPENCODE_SESSION_ID FM_V2_ACTIVATION
# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"
v2_assert_test_namespace || exit 1

# Cross-tree runs (FM_V2_TEST_CODE_ROOT) exercise that tree's recovery helpers,
# matching the acceptance library's code-root selection.
CODE_ROOT=$(cd -P "${FM_V2_TEST_CODE_ROOT:-$ROOT}" && pwd -P)
WATCH_ARM="$CODE_ROOT/bin/fm-watch-arm.sh"
DRAIN="$CODE_ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-wake-admission)
export NODE_NO_WARNINGS=1
ARM_PID=

# The lead's handling turn: drain, then the generation-bound acknowledgement.
lead_drain_and_ack() {  # <state>
  local state=$1
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$state/.lead-drain.out" 2> "$state/.lead-drain.err" || return 1
  ack_drain_err "$state" "$state/.lead-drain.err"
}

start_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  while [ "$i" -lt 100 ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
}

# Real first cycle delivers one signal wake; then a handling successor starts.
# Sets EP_GENERATION and EP_WATCHER for the successor; ARM_PID is its arm.
EP_GENERATION=
EP_WATCHER=
open_handling_episode() {  # <dir>
  local dir=$1 home=$1/home state=$1/state fakebin=$1/fakebin first generation pid
  mkdir -p "$home/data"
  start_arm "$home" "$state" "$fakebin" "$dir/first.out"
  first=$ARM_PID
  printf 'done: alpha finished\n' > "$state/alpha.status"
  wait_for_exit "$first" 120 >/dev/null || fail "fixture watcher did not deliver its wake"
  grep -q '^signal:' "$dir/first.out" || fail "first cycle did not report its wake: $(cat "$dir/first.out")"
  start_arm "$home" "$state" "$fakebin" "$dir/successor.out" "$first"
  generation=$(sed -n 's/^watcher: started pid=[0-9]*.* recovery-generation=\([A-Za-z0-9._-]*\)$/\1/p' "$dir/successor.out")
  pid=$(sed -n 's/^watcher: started pid=\([0-9]*\).* recovery-generation=.*$/\1/p' "$dir/successor.out")
  [ -n "$generation" ] && [ -n "$pid" ] || fail "handling successor did not report a recovery generation: $(cat "$dir/successor.out")"
  EP_GENERATION=$generation
  EP_WATCHER=$pid
}

test_handoff_before_lead_ack_is_accepted() {
  local dir state generation pid
  dir=$(make_case handoff-before-ack)
  state="$dir/state"
  open_handling_episode "$dir"
  generation=$EP_GENERATION
  pid=$EP_WATCHER
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" --watcher-pid "$pid" \
    || fail "handoff confirmation was rejected while the episode was open"
  lead_drain_and_ack "$state" || fail "lead acknowledgement after an accepted handoff failed"
  case "$(cat "$state/.watcher-down")" in acked:*:"$generation") ;; *) fail "episode not retired: $(cat "$state/.watcher-down")" ;; esac
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged wake stayed queued"
  kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
  pass "helper contract: handoff confirmed before the lead acknowledges is accepted and the episode retires"
}

test_handoff_after_lead_ack_is_rejected() {
  local dir state generation pid status=0
  dir=$(make_case handoff-after-ack)
  state="$dir/state"
  open_handling_episode "$dir"
  generation=$EP_GENERATION
  pid=$EP_WATCHER
  # The lead received the wake (admission succeeded), drained and acknowledged
  # it before the adapter's late confirmation ran.
  lead_drain_and_ack "$state" || fail "lead acknowledgement failed"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" --watcher-pid "$pid" \
    || status=$?
  [ "$status" -ne 0 ] || fail "a handoff confirmed after the lead acknowledged the episode was accepted"
  is_live_non_zombie "$ARM_PID" || fail "the live successor did not survive the rejected late handoff"
  kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
  pass "helper contract: a handoff confirmed after the lead acknowledged is rejected, so confirmation must precede admission"
}

FAILED=0
for t in \
  test_handoff_before_lead_ack_is_accepted \
  test_handoff_after_lead_ack_is_rejected; do
  ( "$t" ) || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] || { printf 'not ok - %s wake admission case(s) failed\n' "$FAILED" >&2; exit 1; }
