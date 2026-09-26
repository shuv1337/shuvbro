#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_transport_success_is_not_reply_success() {
  local home state corr
  home=$(setup_parent transport-not-reply)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=5000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "ping")
  fm_pending_reply_mark_delivered "$state" "$corr" || fail "mark delivered failed"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "delivery must leave phase awaiting_report, got $(phase_of "$state" "$corr")"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "delivery alone must not resolve"
  fi
  pass "transport success cannot masquerade as reply success"
}
test_undelivered_records_are_scan_immutable() {
  (
    local home state sm_home corr rec before after
    home=$(setup_parent undelivered-scan)
    state="$home/state"
    sm_home="$home/sm"
    mkdir -p "$sm_home/state"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=5500
    corr=$(fm_pending_reply_create "$home" "$state" hibit "not delivered yet")
    rec=$(fm_pending_reply_path "$state" "$corr")
    printf 'done [corr=%s]: arrived too early\n' "$corr" > "$state/hibit.status"
    printf 'done [corr=%s]: wrong home too early\n' "$corr" > "$sm_home/state/hibit.status"
    fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "sess:fm-hibit"
    before=$(cat "$rec")
    if fm_pending_reply_try_resolve "$state" "$corr"; then
      fail "undelivered expectation must not resolve"
    fi
    fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
      || fail "undelivered wrong-home check should be inert"
    fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home" \
      || fail "undelivered direct tick should be inert"
    fm_backend_busy_state() { fail "undelivered watcher tick must not probe the backend"; }
    fm_backend_capture() { fail "undelivered watcher tick must not capture the backend"; }
    fm_pending_reply_tick "$state" || fail "undelivered watcher tick should succeed"
    after=$(cat "$rec")
    [ "$after" = "$before" ] || fail "scan paths must not mutate an undelivered record"
    fm_pending_reply_mark_delivered "$state" "$corr" || fail "delivery marker should succeed"
    fm_pending_reply_tick_one "$state" "$corr" unknown "$sm_home" \
      || fail "delivered direct tick should succeed"
    [ "$(phase_of "$state" "$corr")" = resolved ] \
      || fail "correlated parent status should resolve after delivery"
  ) || fail "undelivered scan immutability regression failed"
  pass "undelivered records remain immutable across scan paths"
}

test_transport_success_is_not_reply_success
test_undelivered_records_are_scan_immutable
