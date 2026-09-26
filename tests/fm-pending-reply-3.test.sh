#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_unrelated_and_stale_corr_cannot_resolve() {
  local home state corr other
  home=$(setup_parent stale-corr)
  state="$home/state"
  # Reset the fixture clock after isolated subshell tests.
  # shellcheck disable=SC2031
  export FM_PENDING_REPLY_NOW=6000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "need answer")
  fm_pending_reply_mark_delivered "$state" "$corr"
  other=$(fm_pending_reply_new_id)
  printf 'done [corr=%s]: wrong token\n' "$other" > "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "stale/wrong corr must not resolve"
  fi
  printf 'working: still thinking\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "unrelated working line must not resolve"
  fi
  printf 'done: finished without corr\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "status without corr must not resolve"
  fi
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase must stay awaiting_report"
  pass "unrelated events and stale correlation ids cannot resolve"
}
test_wrong_home_detected_not_acknowledged() {
  local home state sm_home corr rec hits
  home=$(setup_parent wrong-home)
  state="$home/state"
  sm_home="$TMP_ROOT/sm-home-$RANDOM"
  mkdir -p "$sm_home/state"
  export FM_PENDING_REPLY_NOW=8000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "report to parent")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Historical incident shape: report written under the secondmate home.
  printf 'done [corr=%s]: stranded in self-home\n' "$corr" > "$sm_home/state/hibit.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "wrong-home detect should succeed"
  rec=$(fm_pending_reply_path "$state" "$corr")
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 1 ] || fail "first wrong-home sighting should count once, got $hits"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "repeated wrong-home detect should succeed"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 1 ] || fail "unchanged wrong-home history should remain one hit, got $hits"
  printf 'done [corr=%s]: second stranded report\n' "$corr" >> "$sm_home/state/hibit.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "new wrong-home sighting detect should succeed"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 2 ] || fail "distinct wrong-home reports should each count once, got $hits"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "repeated distinct wrong-home detect should succeed"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 2 ] || fail "repeated polling should preserve two distinct hits, got $hits"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "wrong-home must not silently acknowledge (phase=$(phase_of "$state" "$corr"))"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "wrong-home status must not resolve via parent path"
  fi
  pass "wrong-home reports are detected but do not silently acknowledge"
}
test_unmarked_captain_input_creates_no_expectation() {
  local dir fb log home rc pending_count
  dir="$TMP_ROOT/unmarked"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent unmarked)
  # Crewmate target stays unmarked and creates no pending-reply record.
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "build" "captain says hello"; rc=$?
  expect_code 0 "$rc" "unmarked crewmate send should succeed"
  [ "$(latest_record_body "$home" build)" = "captain says hello" ] \
    || fail "crewmate steer should be recorded unmarked"$'\n'"$(latest_record_body "$home" build | od -An -c)"
  pending_count=$(find "$home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$pending_count" = 0 ] || fail "unmarked input must create no pending-reply records (got $pending_count)"
  pass "direct unmarked captain input creates no expectation"
}

test_unrelated_and_stale_corr_cannot_resolve
test_wrong_home_detected_not_acknowledged
test_unmarked_captain_input_creates_no_expectation
