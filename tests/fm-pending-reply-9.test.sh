#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_delivery_confirmation_serializes_with_reconciliation() {
  (
    local home state corr rec calls entered release confirm_pid reconcile_pid count i
    home=$(setup_parent delivery-confirm-reconcile-race)
    state="$home/state"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=5900
    corr=$(fm_pending_reply_create "$home" "$state" hibit "serialized delivery")
    rec=$(fm_pending_reply_path "$state" "$corr")
    calls="$home/mark-delivered.calls"
    entered="$home/mark-delivered.entered"
    release="$home/mark-delivered.release"
    fm_pending_reply_mark_delivered() {
      local pending_state=$1 pending_corr=$2 epoch=$3 pending_rec phase
      printf '%s\n' "${BASHPID:-$$}" >> "$calls"
      : > "$entered"
      while [ ! -e "$release" ]; do /bin/sleep 0.01; done
      pending_rec=$(fm_pending_reply_path "$pending_state" "$pending_corr")
      fm_pending_reply_set "$pending_rec" delivered_epoch "$epoch" || return 1
      phase=$(fm_pending_reply_get "$pending_rec" phase)
      [ "$phase" != delivery_unknown ] \
        || fm_pending_reply_set "$pending_rec" phase awaiting_report
    }
    fm_pending_reply_confirm_delivery "$state" "$corr" &
    # The background PID is consumed within this isolated test subshell.
    # shellcheck disable=SC2031
    confirm_pid=$!
    for i in $(seq 1 100); do
      [ -e "$entered" ] && break
      /bin/sleep 0.01
    done
    [ -e "$entered" ] || fail "delivery confirmation did not reach its commit boundary"
    fm_pending_reply_reconcile_delivery "$state" "$corr" &
    # The background PID is consumed within this isolated test subshell.
    # shellcheck disable=SC2031
    reconcile_pid=$!
    /bin/sleep 0.1
    : > "$release"
    wait "$confirm_pid" || fail "delivery confirmation should commit"
    wait "$reconcile_pid" || fail "reconciliation should observe committed delivery"
    count=$(wc -l < "$calls" | tr -d ' ')
    [ "$count" = 1 ] \
      || fail "confirmation and reconciliation raced through $count delivery commits"
    [ "$(fm_pending_reply_get "$rec" delivered_epoch)" = 5900 ] \
      || fail "serialized confirmation should retain delivered_epoch"
    [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
      || fail "serialized confirmation should retain awaiting_report phase"
    [ ! -e "$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")" ] \
      || fail "serialized delivery marker should be removed"
  ) || fail "delivery confirmation serialization regression failed"
  pass "delivery confirmation serializes with reconciliation"
}

test_delivery_confirmation_serializes_with_reconciliation
