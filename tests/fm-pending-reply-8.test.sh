#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_delivery_confirmation_fallback_reconciles() {
  (
    local home state corr rec marker rc prepared_corr prepared_rec prepared_marker escalations
    local reported_corr reported_rec reported_marker
    home=$(setup_parent delivery-confirmation)
    state="$home/state"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=5750
    corr=$(fm_pending_reply_create "$home" "$state" hibit "confirmed delivery")
    rec=$(fm_pending_reply_path "$state" "$corr")
    fm_pending_reply_mark_delivered() { return 1; }
    if fm_pending_reply_confirm_delivery "$state" "$corr"; then
      fail "primary delivery commit failure should be reported"
    else
      rc=$?
    fi
    [ "$rc" = 2 ] || fail "durable fallback should return status 2, got $rc"
    marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
    [ -f "$marker" ] || fail "delivery confirmation fallback marker should persist"
    [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
      || fail "failed primary commit should leave delivered_epoch empty"
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    fm_pending_reply_tick_one "$state" "$corr" unknown \
      || fail "watcher should reconcile the delivery marker"
    [ "$(fm_pending_reply_get "$rec" delivered_epoch)" = 5750 ] \
      || fail "watcher should restore the confirmed delivery epoch"
    [ ! -e "$marker" ] || fail "reconciled delivery marker should be removed"
    prepared_corr=$(fm_pending_reply_create "$home" "$state" hibit "prepared delivery")
    prepared_rec=$(fm_pending_reply_path "$state" "$prepared_corr")
    fm_pending_reply_prepare_delivery "$state" "$prepared_corr" \
      || fail "delivery preparation should persist before transport"
    fm_pending_reply_set "$prepared_rec" grace_secs 10 \
      || fail "delivery-unknown grace fixture should persist"
    prepared_marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$prepared_corr")
    [ -f "$prepared_marker" ] || fail "prepared delivery marker should persist"
    fm_pending_reply_tick_one "$state" "$prepared_corr" unknown \
      || fail "watcher should preserve interrupted delivery state"
    [ "$(phase_of "$state" "$prepared_corr")" = awaiting_report ] \
      || fail "attempted delivery should remain pending during bounded grace"
    [ -z "$(fm_pending_reply_get "$prepared_rec" delivered_epoch)" ] \
      || fail "attempted delivery must never be promoted without confirmation"
    [ -e "$prepared_marker" ] || fail "unknown delivery marker should remain durable"
    export FM_PENDING_REPLY_NOW=5760
    fm_pending_reply_write_delivery_confirmation \
      "$state" "$prepared_corr" attempted 5750 \
      || fail "orphaned attempt fixture should persist"
    fm_pending_reply_tick_one "$state" "$prepared_corr" unknown \
      || fail "orphaned delivery attempt should escalate"
    [ "$(phase_of "$state" "$prepared_corr")" = escalated ] \
      || fail "orphaned delivery attempt should become one durable escalation"
    [ -z "$(fm_pending_reply_get "$prepared_rec" delivered_epoch)" ] \
      || fail "delivery-unknown escalation must not manufacture delivery"
    grep -Fq "pending-reply-delivery-unknown:" "$state/hibit.status" \
      || fail "delivery uncertainty should use its distinct escalation"
    fm_pending_reply_tick_one "$state" "$prepared_corr" unknown \
      || fail "repeated delivery-unknown tick should be inert"
    escalations=$(grep -Fc "blocked [key=pending-reply-$prepared_corr]:" "$state/hibit.status")
    [ "$escalations" = 1 ] \
      || fail "delivery-unknown escalation should publish once, got $escalations"
    printf 'done [corr=%s]: late report proves delivery\n' "$prepared_corr" >> "$state/hibit.status"
    fm_pending_reply_tick "$state" || fail "watcher should accept a late delivery report"
    [ "$(phase_of "$state" "$prepared_corr")" = resolved ] \
      || fail "late report should resolve escalated delivery-unknown"
    [ "$(fm_pending_reply_get "$prepared_rec" delivered_epoch)" = 5760 ] \
      || fail "late report should provide delivery evidence"
    escalations=$(grep -Fc "blocked [key=pending-reply-$prepared_corr]:" "$state/hibit.status")
    [ "$escalations" = 1 ] || fail "late report must not re-escalate delivery-unknown"
    fm_pending_reply_tick "$state" || fail "resolved late report should remain idempotent"
    [ "$(phase_of "$state" "$prepared_corr")" = resolved ] \
      || fail "late report resolution should remain durable"
    export FM_PENDING_REPLY_NOW=5800
    reported_corr=$(fm_pending_reply_create "$home" "$state" hibit "reported delivery")
    reported_rec=$(fm_pending_reply_path "$state" "$reported_corr")
    fm_pending_reply_prepare_delivery "$state" "$reported_corr" \
      || fail "reported delivery attempt should persist"
    reported_marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$reported_corr")
    printf 'done [corr=%s]: report proves delivery\n' "$reported_corr" >> "$state/hibit.status"
    fm_pending_reply_try_resolve "$state" "$reported_corr" \
      || fail "attempted delivery with a report should resolve directly"
    [ "$(phase_of "$state" "$reported_corr")" = resolved ] \
      || fail "correlated report should resolve attempted delivery"
    [ "$(fm_pending_reply_get "$reported_rec" delivered_epoch)" = 5800 ] \
      || fail "correlated report should provide delivery evidence"
    [ ! -e "$reported_marker" ] || fail "resolved delivery marker should be removed"
    fm_pending_reply_tick_one "$state" "$reported_corr" unknown \
      || fail "resolved attempted delivery should remain inert in watcher"
    if grep -Fq "pending-reply-id=$reported_corr" "$state/hibit.status"; then
      fail "reported attempted delivery must not escalate as delivery-unknown"
    fi
  ) || fail "delivery confirmation fallback regression failed"
  pass "delivery confirmation fallback reconciles durably"
}

test_delivery_confirmation_fallback_reconciles
