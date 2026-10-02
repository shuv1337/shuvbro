#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_legacy_escalation_does_not_close_taken_default_decision() {
  local home state corr rec open
  home=$(setup_parent legacy-escalation)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4750
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "legacy escalation")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase escalated
  fm_pending_reply_set "$rec" escalated_epoch 4700
  printf 'blocked: pending-reply-missed: task=hibit pending-reply-id=%s request=legacy escalation\n' "$corr" \
    > "$state/hibit.status"
  printf 'blocked: unrelated operator decision\n' >> "$state/hibit.status"
  printf 'done [corr=%s]: delayed legacy reply\n' "$corr" >> "$state/hibit.status"

  fm_pending_reply_try_resolve "$state" "$corr" || fail "legacy reply should resolve its record"
  if grep -Fq 'resolved [key=default]: pending-reply-resolved:' "$state/hibit.status"; then
    fail "legacy escalation emitted an unsafe default-key resolution"
  fi
  fm_pending_reply_tick "$state" || fail "legacy close retry failed"
  open=$(status_open_decisions "$state/hibit.status")
  assert_contains "$open" "unrelated operator decision" \
    "legacy escalation closure hid an unrelated default-key decision"
  pass "legacy escalation cannot close an unrelated default-key decision"
}
test_foreign_blocker_is_not_selected_as_escalation() {
  local home state corr rec open
  home=$(setup_parent foreign-blocker)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4775
  export FM_PENDING_REPLY_SEND_HOOK=true
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "foreign blocker")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "genuine escalation failed"
  rec=$(fm_pending_reply_path "$state" "$corr")
  printf 'blocked [key=release]: foreign decision pending-reply-id=%s corr=%s\n' \
    "$corr" "$corr" >> "$state/hibit.status"

  fm_pending_reply_try_resolve "$state" "$corr" || fail "correlated foreign blocker should resolve the record"
  open=$(status_open_decisions "$state/hibit.status")
  assert_contains "$open" $'release\tblocked\tforeign decision' \
    "pending-reply closure cleared the foreign release decision"
  assert_not_contains "$open" "pending-reply-$corr" \
    "genuine keyed escalation remained open"
  assert_no_grep 'resolved [key=release]: pending-reply-resolved:' "$state/hibit.status" \
    "foreign release decision was selected as the pending-reply escalation"
  [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] \
    || fail "genuine keyed escalation closure was not recorded"
  pass "foreign correlated blocker cannot impersonate a pending-reply escalation"
}
test_concurrent_resolution_closes_escalation_once() {
  local home state corr rec
  home=$(setup_parent concurrent-resolution)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4800
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "concurrent resolution")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase escalated
  fm_pending_reply_set "$rec" escalated_epoch 4750
  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=hibit pending-reply-id=%s request=concurrent resolution\n' \
    "$corr" "$corr" > "$state/hibit.status"
  printf 'done [corr=%s]: concurrent delayed reply\n' "$corr" >> "$state/hibit.status"

  for _ in 1 2 3 4 5 6 7 8; do
    fm_pending_reply_try_resolve "$state" "$corr" &
  done
  wait

  [ "$(phase_of "$state" "$corr")" = resolved ] \
    || fail "concurrent resolvers left the expectation unresolved"
  [ "$(grep -Fc "pending-reply-resolved: task=hibit pending-reply-id=$corr" "$state/hibit.status")" -eq 1 ] \
    || fail "concurrent resolvers did not append exactly one decision close"
  [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] \
    || fail "concurrent resolution did not record the closed escalation"
  pass "concurrent resolution closes one keyed escalation exactly once"
}
test_concurrent_escalation_yields_to_late_reply() {
  local home state corr rec
  home=$(setup_parent concurrent-escalation)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4900
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "concurrent escalation")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase recovery_sent
  fm_pending_reply_set "$rec" recovery_turn_completed_epoch 4850
  printf 'done [corr=%s]: late concurrent reply\n' "$corr" > "$state/hibit.status"

  for _ in 1 2 3 4 5 6 7 8; do
    fm_pending_reply_maybe_escalate "$state" "$corr" &
    fm_pending_reply_try_resolve "$state" "$corr" &
  done
  wait

  [ "$(phase_of "$state" "$corr")" = resolved ] \
    || fail "concurrent escalation overwrote a resolved expectation"
  assert_no_grep "pending-reply-id=$corr" "$state/hibit.status" \
    "concurrent escalation published a false missed-reply blocker"
  [ -z "$(fm_pending_reply_get "$rec" escalated_epoch)" ] \
    || fail "concurrent escalation committed after the reply resolved"
  pass "concurrent escalation yields to a late correlated reply"
}

test_legacy_escalation_does_not_close_taken_default_decision
test_foreign_blocker_is_not_selected_as_escalation
test_concurrent_resolution_closes_escalation_once
test_concurrent_escalation_yields_to_late_reply
