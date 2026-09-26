#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_fm_send_marked_secondmate_creates_pending_and_embeds_corr() {
  local dir fb log home rc got corr rec
  dir="$TMP_ROOT/send-pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent send-pending)
  fm_write_secondmate_meta "$home/state/hibit.meta" "$home/sm" "sess:fm-hibit"
  run_send "$fb" "$home" "$log" "hibit" "audit the build"; rc=$?
  expect_code 0 "$rc" "secondmate send should succeed"
  got=$(latest_record_body "$home" hibit)
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "secondmate steer record must embed marker+corr"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  corr=$(fm_pending_reply_extract_corr "$got")
  [ "${#corr}" -eq 16 ] || fail "corr id should be 16 hex chars, got '$corr'"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ -f "$rec" ] || fail "pending-reply record must exist after marked send"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "phase should be awaiting_report after delivery"
  [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "delivered_epoch must be set after successful send"
  [ "$(fm_pending_reply_get "$rec" task_id)" = hibit ] \
    || fail "task_id must match secondmate id"
  pass "fm-send marked secondmate path creates pending and embeds corr"
}
test_document_pointer_resolves() {
  local home state corr
  home=$(setup_parent doc-pointer)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "deep audit")
  fm_pending_reply_mark_delivered "$state" "$corr"
  printf 'done [corr=%s]: see data/hibit/report.md\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "document pointer status should resolve"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" = document ] \
    || fail "resolved_via should be document"
  pass "status-pointed document resolves the expectation"
}
test_helper_report_resolves() {
  local home state corr sm_home
  home=$(setup_parent helper)
  state="$home/state"
  sm_home=$(bind_local_mate "$home" hibit)
  export FM_PENDING_REPLY_NOW=9100
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "quick answer")
  fm_pending_reply_mark_delivered "$state" "$corr"
  FM_HOME="$sm_home" "$REPORT" "done" "$corr" "all good" \
    || fail "helper report failed"
  [ -f "$state/hibit.status" ] || fail "helper must write the parent channel"
  if grep -Fq "corr=$corr" "$sm_home/state/hibit.status" 2>/dev/null; then
    fail "helper must not write the mate home's own status file"
  fi
  fm_pending_reply_try_resolve "$state" "$corr" || fail "helper report should resolve"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" = helper ] \
    || fail "resolved_via should be helper"
  pass "optional helper report resolves without being required for correctness"
}
test_busy_idle_observation_via_backend_abstraction() {
  local home state corr
  home=$(setup_parent busy-idle)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9200
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "backend turn")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Simulates Pi/Claude secondmate busy_state from fm_backend_busy_state without
  # reading conversation text (herdr native idle/busy or tmux unknown fallback).
  fm_pending_reply_observe_busy "$state" "$corr" unknown
  [ -z "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_turn_completed_epoch)" ] \
    || fail "unknown busy_state must not prove turn completion"
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  [ -n "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_turn_completed_epoch)" ] \
    || fail "busy->idle must prove turn completion"
  pass "backend busy/idle observation covers Pi/Claude paths without conversation scrape"
}

test_fm_send_marked_secondmate_creates_pending_and_embeds_corr
test_document_pointer_resolves
test_helper_report_resolves
test_busy_idle_observation_via_backend_abstraction
