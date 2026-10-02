#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_restart_preserves_expectation_and_parent_destination() {
  local home state corr rec parent_status parent_home
  home=$(setup_parent restart)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=7000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "survive restart")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  parent_home=$(fm_pending_reply_get "$rec" parent_home)
  # Simulate process restart: re-source library and re-read the same record.
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  [ -f "$rec" ] || fail "record must survive restart"
  [ "$(fm_pending_reply_get "$rec" parent_status)" = "$parent_status" ] \
    || fail "parent_status must be stable across restart"
  [ "$(fm_pending_reply_get "$rec" parent_home)" = "$parent_home" ] \
    || fail "parent_home must be stable across restart"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase preserved"
  # Compaction-safe: destination is absolute path fields, not chat memory.
  case "$parent_status" in
    /*.status) : ;;
    *) fail "parent_status should be an absolute status path, got $parent_status" ;;
  esac
  pass "restart preserves expectation and exact parent destination"
}

test_restart_preserves_expectation_and_parent_destination
