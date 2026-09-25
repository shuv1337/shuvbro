#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_same_basename_reply_resolves_after_recovery_failure() {
  local home state sm_home corr rec parent_status
  home=$(setup_parent same-basename-after-recovery-failure)
  state="$home/state"
  sm_home=$(bind_local_mate "$home" mate)
  export FM_PENDING_REPLY_NOW=11050
  export FM_PENDING_REPLY_SEND_HOOK=false

  corr=$(fm_pending_reply_create "$home" "$state" mate "status after failed recovery")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "recovery fixture must fail delivery"
  fi
  [ "$(phase_of "$state" "$corr")" = recovery_failed ] \
    || fail "fixture should reach recovery_failed"
  rec=$(fm_pending_reply_path "$state" "$corr")
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  fm_write_secondmate_meta "$state/mate.meta" "$sm_home"
  printf 'done [corr=%s]: answer landed after recovery failure\n' "$corr" \
    > "$sm_home/state/mate.status"

  fm_pending_reply_tick "$state"
  [ "$(phase_of "$state" "$corr")" = resolved ] \
    || fail "late same-basename reply must resolve before recovery failure escalation"
  grep -Fq "corr=$corr" "$parent_status" \
    || fail "late reply must be restated onto the parent channel"
  if grep -Fq pending-reply-recovery-delivery "$parent_status"; then
    fail "authorized late reply must prevent recovery delivery escalation"
  fi
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "same-basename reply resolves at the recovery failure boundary"
}

test_child_status_wrong_home_is_not_copied() {
  local home state sm_home corr rec hook_log status_file expected_display stored_first
  home=$(setup_parent child-wrong-home)
  state="$home/state"
  sm_home="$TMP_ROOT/team,west-home-$RANDOM"
  mkdir -p "$sm_home/state"
  hook_log="$TMP_ROOT/child-wrong-home.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf 'recovered\n' >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK=recovery_hook
  export FM_PENDING_REPLY_NOW=11100

  corr=$(fm_pending_reply_create "$home" "$state" mate "status of the audit")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  status_file="$sm_home/state/"$'child\nphase=resolved\nteam,west.status'
  printf 'done [corr=%s]: leaked into a child file\n' "$corr" > "$status_file"

  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "a child-file sighting must not acknowledge, got $(phase_of "$state" "$corr")"
  [ -z "$(fm_pending_reply_get "$rec" resolved_epoch)" ] \
    || fail "resolved_epoch must stay empty for a child-file sighting"
  grep -Fq pending-reply-missed "$state/mate.status" \
    || fail "a child-file miss should still escalate"
  printf -v expected_display '%q' "$status_file"
  expected_display="$expected_display:1"
  grep -Fq "token seen in $expected_display;" "$state/mate.status" \
    || fail "missed payload must preserve the complete readable child-file path"$'\n'"$(cat "$state/mate.status")"
  stored_first=$(fm_pending_reply_get "$rec" wrong_home_first_sighting)
  [ "$(fm_pending_reply_sighting_display "$stored_first")" = "$expected_display" ] \
    || fail "encoded wrong-home sighting must reversibly preserve the crafted path"
  [ "$(grep -c '^phase=' "$rec")" = 1 ] \
    || fail "crafted filename must not inject a phase field into the pending record"
  if grep -Fq "corr=$corr" "$state/mate.status"; then
    fail "a child status file must not be restatement-copied onto the parent channel"
  fi
  [ "$(fm_pending_reply_get "$rec" wrong_home_hits)" = 1 ] \
    || fail "the child file should count as one wrong-home sighting"
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "a child-file mate-home sighting is not copied and still escalates"
}

test_mechanical_helper_writes_parent_channel() {
  local home state sm_home corr empty_corr rc
  home=$(setup_parent mechanical-helper)
  state="$home/state"
  sm_home=$(bind_local_mate "$home" mate)
  export FM_PENDING_REPLY_NOW=11200
  corr=$(fm_pending_reply_create "$home" "$state" mate "status of the audit")
  fm_pending_reply_mark_delivered "$state" "$corr"
  FM_HOME="$sm_home" "$REPORT" "done" "$corr" "audit clean" \
    || fail "mechanical helper should succeed from a seeded mate home"
  grep -Fq "corr=$corr" "$state/mate.status" \
    || fail "mechanical helper must append to the parent channel"
  if [ -e "$sm_home/state/mate.status" ]; then
    fail "mechanical helper must not write the mate home's same-basename status file"
  fi
  fm_pending_reply_try_resolve "$state" "$corr" \
    || fail "a mechanical helper line on the parent channel must resolve"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase should be resolved"
  empty_corr=$(fm_pending_reply_create "$home" "$state" mate "answer must not be empty")
  fm_pending_reply_mark_delivered "$state" "$empty_corr"
  rc=0
  FM_HOME="$sm_home" "$REPORT" "done" "$empty_corr" "" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "helper must reject an empty status note"
  if fm_pending_reply_try_resolve "$state" "$empty_corr"; then
    fail "an empty helper report must not resolve an expectation"
  fi
  rc=0
  env -u FM_HOME "$REPORT" "done" "$empty_corr" "must require FM_HOME" \
    2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "helper must require FM_HOME"
  rc=0
  FM_HOME="$home" "$REPORT" "done" "$corr" "from a main home" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "helper must refuse a main home that has no parent channel"
  pass "mechanical helper writes the parent channel from verb, corr, and note"
}

test_remote_parent_replies_is_not_wrong_home() {
  local home state sm_home corr rec hits
  home=$(setup_parent remote-parent-replies)
  state="$home/state"
  sm_home="$TMP_ROOT/remote-replies-home-$RANDOM"
  mkdir -p "$sm_home/state"
  printf '%s\n' mate > "$sm_home/.fm-secondmate-home"
  cat > "$sm_home/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=remote
parent_host=remote.example
EOF
  export FM_PENDING_REPLY_NOW=11300
  corr=$(fm_pending_reply_create "$home" "$state" mate "did the build go green")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  printf 'done [corr=%s]: mirrored answer\n' "$corr" > "$sm_home/state/parent-replies.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "wrong-home detect should succeed over a remote channel file"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 0 ] || fail "parent-replies.status must not increment wrong_home_hits, got $hits"
  printf 'done [corr=%s]: leaked into a child file\n' "$corr" > "$sm_home/state/child.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "wrong-home detect should succeed after a child-file leak"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 1 ] || fail "a sibling child status file should still count once, got $hits"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "detect must not acknowledge a remote-channel or child-file sighting"
  pass "remote parent-replies.status is not classified as wrong-home"
}

test_local_parent_replies_is_wrong_home_evidence() {
  local home state sm_home corr rec hits first
  home=$(setup_parent local-parent-replies)
  state="$home/state"
  sm_home=$(bind_local_mate "$home" mate)
  export FM_PENDING_REPLY_NOW=11350
  corr=$(fm_pending_reply_create "$home" "$state" mate "did the build go green")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  printf 'done [corr=%s]: written to a local alias\n' "$corr" \
    > "$sm_home/state/parent-replies.status"

  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "wrong-home detect should scan a local parent-replies alias"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 1 ] || fail "local parent-replies.status should count once, got $hits"
  first=$(fm_pending_reply_get "$rec" wrong_home_first_sighting)
  [ "$(fm_pending_reply_sighting_display "$first")" = \
    "$sm_home/state/parent-replies.status:1" ] \
    || fail "local parent-replies sighting must retain its readable path"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "local wrong-home evidence must not acknowledge the reply"
  pass "local parent-replies.status remains wrong-home evidence"
}

test_failed_send_discards_undelivered_expectation() {
  local home state corr
  home=$(setup_parent discard)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9400
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "never lands")
  # Not delivered: discard is allowed.
  fm_pending_reply_discard_undelivered "$state" "$corr" || fail "discard undelivered failed"
  [ ! -f "$(fm_pending_reply_path "$state" "$corr")" ] \
    || fail "undelivered record should be removed"
  # Delivered records must not be discarded by this path.
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "landed")
  fm_pending_reply_mark_delivered "$state" "$corr"
  if fm_pending_reply_discard_undelivered "$state" "$corr" 2>/dev/null; then
    fail "delivered record must not be discarded"
  fi
  [ -f "$(fm_pending_reply_path "$state" "$corr")" ] || fail "delivered record must remain"
  pass "failed transport discards undelivered expectation only"
}


test_same_basename_reply_resolves_after_recovery_failure
test_child_status_wrong_home_is_not_copied
test_mechanical_helper_writes_parent_channel
test_remote_parent_replies_is_not_wrong_home
test_local_parent_replies_is_wrong_home_evidence
test_failed_send_discards_undelivered_expectation
