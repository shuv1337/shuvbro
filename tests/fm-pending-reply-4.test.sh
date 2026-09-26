#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"

test_unknown_backend_state_uses_capture_fallback() {
  local backend
  for backend in tmux zellij; do
    (
      local home state corr rec sm_home
      home=$(setup_parent "fallback-$backend")
      state="$home/state"
      sm_home="$home/sm"
      mkdir -p "$sm_home/state"
      export FM_PENDING_REPLY_GRACE_SECS=10
      # These fixture overrides are intentionally scoped to the isolated subshell.
      # shellcheck disable=SC2030,SC2031
      export FM_PENDING_REPLY_NOW=10000
      corr=$(fm_pending_reply_create "$home" "$state" "hibit" "$backend fallback")
      fm_pending_reply_mark_delivered "$state" "$corr"
      fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "session:fm-hibit" alpha pi
      [ "$backend" = tmux ] || printf 'backend=%s\n' "$backend" >> "$state/hibit.meta"
      fm_backend_busy_state() { printf 'unknown'; }
      fm_backend_capture() { printf '%s' "$FM_PENDING_TEST_CAPTURE"; }
      # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
      # shellcheck disable=SC2329
      recovery_hook() { :; }
      # This hook override is intentionally scoped to the isolated subshell.
      # shellcheck disable=SC2030,SC2031
      export FM_PENDING_REPLY_SEND_HOOK=recovery_hook
      export FM_PENDING_TEST_CAPTURE='idle footer'
      fm_pending_reply_tick "$state"
      rec=$(fm_pending_reply_path "$state" "$corr")
      [ -z "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
        || fail "$backend fallback must not accept stale idle before grace"
      # Continue advancing the subshell-local fixture clock.
      # shellcheck disable=SC2030,SC2031
      export FM_PENDING_REPLY_NOW=10010
      fm_pending_reply_tick "$state"
      [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
        || fail "$backend fallback idle should trigger recovery after grace"
      export FM_PENDING_REPLY_NOW=10011
      export FM_PENDING_TEST_CAPTURE='Working...'
      fm_pending_reply_tick "$state"
      export FM_PENDING_REPLY_NOW=10012
      export FM_PENDING_TEST_CAPTURE='idle footer'
      fm_pending_reply_tick "$state"
      [ "$(phase_of "$state" "$corr")" = escalated ] \
        || fail "$backend capture busy-to-idle should complete recovery turn"
    ) || fail "$backend unknown-state capture fallback failed"
  done
  pass "tmux and zellij unknown states use bounded capture fallback"
}

test_kimi_capture_fallback_uses_recorded_harness() (
  local home state corr rec sm_home
  home=$(setup_parent kimi-fallback)
  state="$home/state"
  sm_home="$home/sm"
  mkdir -p "$sm_home/state"
  # This fixture clock is intentionally scoped to the isolated subshell.
  # shellcheck disable=SC2030,SC2031
  export FM_PENDING_REPLY_NOW=10020
  corr=$(fm_pending_reply_create "$home" "$state" hibit "kimi fallback")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "session:fm-hibit" alpha kimi
  fm_backend_busy_state() { printf 'unknown'; }
  fm_backend_capture() { printf '%s' "$FM_PENDING_KIMI_CAPTURE"; }
  export FM_PENDING_KIMI_CAPTURE=' 🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"'

  [ "$(fm_pending_reply_backend_observation tmux session:fm-hibit fm-hibit codex)" = fallback-idle ] \
    || fail "Kimi spinner leaked into another harness"
  export FM_PENDING_KIMI_CAPTURE='Ctrl+c:cancel'
  [ "$(fm_pending_reply_backend_observation tmux session:fm-hibit fm-hibit kimi)" = fallback-idle ] \
    || fail "Grok's exact busy token leaked into Kimi pending-reply observation"
  export FM_PENDING_KIMI_CAPTURE=' 🌑 · Tip: ask Kimi to schedule tasks, e.g. "remind me at 5pm"'
  fm_pending_reply_tick "$state"
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] \
    || fail "recorded Kimi spinner was not observed as busy"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "working Kimi secondmate entered recovery"
  pass "pending replies scope Kimi capture fallback by recorded harness"
)

test_tick_skips_terminal_and_reuses_target_observation() {
  (
    local home state open1 open2 resolved escalated rec probe_log probes scan_log scans snapshot
    home=$(setup_parent observation-cache)
    state="$home/state"
    probe_log="$home/backend-probes.log"
    scan_log="$home/status-scans.log"
    : > "$probe_log"
    : > "$scan_log"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=10100
    open1=$(fm_pending_reply_create "$home" "$state" hibit "first open request")
    open2=$(fm_pending_reply_create "$home" "$state" hibit "second open request")
    fm_pending_reply_mark_delivered "$state" "$open1"
    fm_pending_reply_mark_delivered "$state" "$open2"
    resolved=$(fm_pending_reply_create "$home" "$state" resolved "resolved request")
    fm_pending_reply_mark_delivered "$state" "$resolved"
    printf 'done [corr=%s]: complete\n' "$resolved" > "$state/resolved.status"
    fm_pending_reply_try_resolve "$state" "$resolved" || fail "resolved fixture should resolve"
    escalated=$(fm_pending_reply_create "$home" "$state" escalated "escalated request")
    fm_pending_reply_mark_delivered "$state" "$escalated"
    rec=$(fm_pending_reply_path "$state" "$escalated")
    fm_pending_reply_set "$rec" phase escalated || fail "escalated fixture should transition"
    mkdir -p "$home/escalated/state"
    printf 'done [corr=%s]: wrong home\n' "$escalated" > "$home/escalated/state/child.status"
    fm_write_secondmate_meta "$state/hibit.meta" "$home/hibit" "sess:fm-hibit"
    fm_write_secondmate_meta "$state/resolved.meta" "$home/resolved" "sess:fm-resolved"
    fm_write_secondmate_meta "$state/escalated.meta" "$home/escalated" "sess:fm-escalated"
    # Runtime overrides called indirectly by the pending-reply tick.
    # shellcheck disable=SC2329
    fm_backend_busy_state() {
      printf '%s\t%s\n' "$1" "$2" >> "$probe_log"
      printf 'busy'
    }
    # shellcheck disable=SC2329
    fm_backend_capture() { fail "native busy observations should not capture"; }
    # shellcheck disable=SC2329
    fm_pending_reply_find_resolve_line() {
      local status_file=$1 corr=$2 line
      printf '%s\t%s\n' "$status_file" "$corr" >> "$scan_log"
      [ -f "$status_file" ] || return 0
      while IFS= read -r line || [ -n "$line" ]; do
        fm_pending_reply_line_resolves "$line" "$corr" || continue
        printf '%s' "$line"
        return 0
      done < "$status_file"
      return 0
    }
    fm_pending_reply_tick "$state"
    probes=$(wc -l < "$probe_log" | tr -d ' ')
    [ "$probes" = 1 ] || fail "two open records for one target should use one probe, got $probes"
    rec=$(fm_pending_reply_path "$state" "$open1")
    [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] \
      || fail "cached observation should update the first open record"
    rec=$(fm_pending_reply_path "$state" "$open2")
    [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] \
      || fail "cached observation should update the second open record"
    rec=$(fm_pending_reply_path "$state" "$escalated")
    snapshot=$(fm_pending_reply_get "$rec" wrong_home_scan_signature)
    [ -n "$snapshot" ] || fail "wrong-home scan should persist its file-set signature"
    fm_pending_reply_tick "$state"
    scans=$(wc -l < "$scan_log" | tr -d ' ')
    [ "$scans" = 3 ] \
      || fail "unchanged records should scan two open and one escalated status only once, got $scans"
    [ "$(fm_pending_reply_get "$rec" wrong_home_scan_signature)" = "$snapshot" ] \
      || fail "unchanged wrong-home logs should retain their scan signature"
  ) || fail "terminal-skip and observation-cache regression failed"
  pass "tick skips terminal records and reuses target observations"
}

test_correlations_reuse_only_for_matching_open_task() {
  local dir fb log home state got corr1 corr2 corr3 rec
  dir="$TMP_ROOT/corr-reuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent corr-reuse)
  state="$home/state"
  fm_write_secondmate_meta "$state/domain.meta" "$home/domain" "sess:fm-domain"
  fm_write_secondmate_meta "$state/other.meta" "$home/other" "sess:fm-other"
  run_send "$fb" "$home" "$log" domain "first request" || fail "first marked send failed"
  got=$(latest_record_body "$home" domain)
  corr1=$(fm_pending_reply_extract_corr "$got")
  export FM_PENDING_REPLY_EXISTING_CORR=$corr1
  if run_send "$fb" "$home" "$log" other "forwarded request"; then
    fail "an explicit cross-task correlation must be refused"
  fi
  unset FM_PENDING_REPLY_EXISTING_CORR
  if latest_record_body "$home" other >/dev/null 2>&1; then
    fail "a refused cross-task correlation must not enqueue a steer"
  fi
  run_send "$fb" "$home" "$log" other "forwarded request" \
    || fail "fresh cross-task send failed"
  corr2=$(fm_pending_reply_extract_corr "$(latest_record_body "$home" other)")
  [ -n "$corr2" ] && [ "$corr2" != "$corr1" ] \
    || fail "cross-task send must receive a new correlation"
  rec=$(fm_pending_reply_path "$state" "$corr2")
  [ "$(fm_pending_reply_get "$rec" task_id)" = other ] \
    || fail "cross-task expectation must belong to the new target"
  printf 'done [corr=%s]: complete\n' "$corr1" > "$state/domain.status"
  fm_pending_reply_try_resolve "$state" "$corr1" || fail "first expectation should resolve"
  run_send "$fb" "$home" "$log" domain "${FM_FROMFIRST_MARK}corr=${corr1} follow-up" \
    || fail "resolved-correlation follow-up failed"
  corr3=$(fm_pending_reply_extract_corr "$(latest_record_body "$home" domain)")
  [ -n "$corr3" ] && [ "$corr3" != "$corr1" ] \
    || fail "resolved correlation must not guard a new send"
  rec=$(fm_pending_reply_path "$state" "$corr3")
  [ "$(fm_pending_reply_get "$rec" task_id)" = domain ] \
    || fail "replacement expectation must belong to the current target"
  pass "correlations are reused only for matching open task records"
}

test_tick_end_to_end_missed_then_escalate() {
  local home state corr hook_log sm_home
  home=$(setup_parent tick-e2e)
  state="$home/state"
  sm_home="$home/sm"
  mkdir -p "$sm_home/state"
  hook_log="$TMP_ROOT/tick-hook.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf 'recovered\n' >> "$hook_log"; }
  export -f recovery_hook
  # Reset hook and clock fixtures after isolated subshell tests.
  # shellcheck disable=SC2031
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  # shellcheck disable=SC2031
  export FM_PENDING_REPLY_NOW=9300

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "e2e miss")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "sess:fm-hibit"
  # Override backend busy via direct tick_one (backend may be unknown in hermetic home).
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "tick should send recovery after idle+grace, got $(phase_of "$state" "$corr")"
  [ -s "$hook_log" ] || fail "recovery should have been sent via tick"
  # Recovery turn completes empty.
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "tick should escalate after second miss, got $(phase_of "$state" "$corr")"
  # Expired age must not erase the unresolved record.
  export FM_PENDING_REPLY_NOW=999999
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ -f "$(fm_pending_reply_path "$state" "$corr")" ] \
    || fail "expiration must never silently erase an unresolved reply"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "must stay escalated"
  pass "tick end-to-end: miss -> one recovery -> escalate -> durable"
}

test_remote_repost_waits_for_the_reply_channel() {
  local home state corr hook_log rec lines
  home=$(setup_parent remote-repost)
  state="$home/state"
  hook_log="$TMP_ROOT/remote-repost.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=5000
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  remote_repost_hook() {
    printf '%s\t%s\n' "$1" "$2" >> "$hook_log"
  }
  export -f remote_repost_hook
  export FM_PENDING_REPLY_SEND_HOOK=remote_repost_hook

  fm_write_meta "$state/ios.meta" \
    "window=fm-remote:w1:p1" "harness=claude" "kind=secondmate" "mode=secondmate" \
    "remote_host=remote-mac" "remote_root=/remote/root" "remote_backend=herdr"
  corr=$(fm_pending_reply_create "$home" "$state" "ios" "status of the iOS build")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  rec=$(fm_pending_reply_path "$state" "$corr")

  # The mate's turn ended, but nothing proves the parent has read the remote
  # reply log since: a repost here would nag for a reply already written there.
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "a remote repost must not fire before the reply channel is known caught up"
  fi
  [ ! -s "$hook_log" ] || fail "no repost may be sent while the reply channel is behind"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "the expectation must stay armed while the reply channel is behind"

  # A watermark from BEFORE the turn ended is still not evidence.
  fm_pending_reply_note_remote_channel_caught_up "$state" ios 4000
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "a stale reply-channel watermark must not license a repost"
  fi
  [ ! -s "$hook_log" ] || fail "a stale watermark must not release a repost"

  # Read through the end of the remote log after the turn: the report really is
  # missing, so the one recovery repost fires.
  fm_pending_reply_note_remote_channel_caught_up "$state" ios \
    "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)"
  fm_pending_reply_send_recovery "$state" "$corr" \
    || fail "a genuinely missed remote report must still trigger its recovery repost"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "phase should be recovery_sent, got $(phase_of "$state" "$corr")"
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "expected exactly one repost, got $lines"
  case "$(cat "$hook_log")" in
    *REPOST\ REQUIRED*) : ;;
    *) fail "the recovery message must ask for a repost"$'\n'"$(cat "$hook_log")" ;;
  esac
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "a remote repost waits for the reply channel and still fires on a real miss"
}

test_mirrored_remote_reply_never_triggers_a_repost() {
  local home state corr hook_log
  home=$(setup_parent remote-mirrored-reply)
  state="$home/state"
  hook_log="$TMP_ROOT/remote-mirrored-reply.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=6000
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  mirrored_reply_hook() {
    printf '%s\t%s\n' "$1" "$2" >> "$hook_log"
  }
  export -f mirrored_reply_hook
  export FM_PENDING_REPLY_SEND_HOOK=mirrored_reply_hook

  fm_write_meta "$state/ios.meta" \
    "window=fm-remote:w1:p1" "harness=claude" "kind=secondmate" "mode=secondmate" \
    "remote_host=remote-mac" "remote_root=/remote/root" "remote_backend=herdr"
  corr=$(fm_pending_reply_create "$home" "$state" "ios" "did the build go green")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  # The mirror caught up AND carried the mate's correlated answer.
  printf 'done [corr=%s]: build is green\n' "$corr" > "$state/ios.status"
  fm_pending_reply_note_remote_channel_caught_up "$state" ios 6000

  fm_pending_reply_tick_one "$state" "$corr" idle || fail "tick should succeed"
  [ "$(phase_of "$state" "$corr")" = resolved ] \
    || fail "a mirrored correlated reply must resolve, got $(phase_of "$state" "$corr")"
  [ ! -s "$hook_log" ] || fail "a correlated remote reply must never trigger a repost"
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "a mirrored correlated remote reply resolves without any repost"
}

test_same_basename_self_home_corr_resolves_on_tick() {
  local home state sm_home corr rec parent_status hook_log
  home=$(setup_parent same-basename-repair)
  state="$home/state"
  sm_home=$(bind_local_mate "$home" mate)
  hook_log="$TMP_ROOT/same-basename-repair.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf 'recovered\n' >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK=recovery_hook
  export FM_PENDING_REPLY_NOW=11000

  corr=$(fm_pending_reply_create "$home" "$state" mate "status of the audit")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  [ "$parent_status" = "$state/mate.status" ] \
    || fail "parent_status should be the parent file, got $parent_status"
  case "$parent_status" in
    "$sm_home"/*) fail "parent_status must not live under the mate home" ;;
  esac
  printf 'done [corr=%s]: stranded in self-home\n' "$corr" > "$sm_home/state/mate.status"
  [ ! -e "$parent_status" ] || fail "parent channel must start empty"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "a mate-home sighting must not resolve through the parent path"
  fi

  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = resolved ] \
    || fail "same-basename self-home corr must resolve, got $(phase_of "$state" "$corr")"
  [ -n "$(fm_pending_reply_get "$rec" resolved_epoch)" ] \
    || fail "resolved_epoch must be set after the restatement copy"
  grep -Fq "corr=$corr" "$parent_status" \
    || fail "parent channel must receive the restated corr= line"
  if grep -Fq pending-reply-missed "$parent_status"; then
    fail "same-basename self-home corr must not escalate as pending-reply-missed"
  fi
  [ ! -s "$hook_log" ] || fail "a restated same-basename reply must not trigger recovery"
  [ "$(fm_pending_reply_get "$rec" wrong_home_hits)" = 1 ] \
    || fail "the stranded file should still count as one wrong-home sighting"
  [ "$(fm_pending_reply_sighting_display \
    "$(fm_pending_reply_get "$rec" wrong_home_first_sighting)")" = \
    "$sm_home/state/mate.status:1" ] \
    || fail "first wrong-home sighting must display the readable mate-home path and line"
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "same-basename self-home corr= is restated onto the parent channel and resolves"
}


test_unknown_backend_state_uses_capture_fallback
test_kimi_capture_fallback_uses_recorded_harness
test_tick_skips_terminal_and_reuses_target_observation
test_correlations_reuse_only_for_matching_open_task
test_tick_end_to_end_missed_then_escalate
test_remote_repost_waits_for_the_reply_channel
test_mirrored_remote_reply_never_triggers_a_repost
test_same_basename_self_home_corr_resolves_on_tick
