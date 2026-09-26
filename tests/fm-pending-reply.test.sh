#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards.
# The suite is split so one ShellCheck process with --external-sources fits
# in the 8g self-hosted container. Shared setup is fm-pending-reply-fixture.sh.
set -u

# shellcheck source=tests/fm-pending-reply-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pending-reply-fixture.sh"


test_normal_correlated_reply_resolves_once() {
  local home state corr status rec
  home=$(setup_parent resolve-once)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=1000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "audit the ledger")
  fm_pending_reply_mark_delivered "$state" "$corr"
  status="$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "missing status must not resolve"
  fi
  printf 'done [corr=%s]: ledger clean\n' "$corr" > "$status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "correlated status should resolve"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase should be resolved"
  # Idempotent second resolve.
  fm_pending_reply_try_resolve "$state" "$corr" || fail "second resolve must stay successful"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase must remain resolved"
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = status ] \
    || fail "resolved_via should be status"
  pass "normal correlated reply resolves once (idempotent)"
}

test_completed_turn_no_report_triggers_one_recovery() {
  local home state corr hook_log rec
  home=$(setup_parent one-recovery)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-hook.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=2000
  export FM_PENDING_REPLY_SEND_HOOK='printf "%s\t%s\n" >>"'"$hook_log"'"'
  # The hook above is wrong for eval form - use a function.
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() {
    printf '%s\t%s\n' "$1" "$2" >> "$hook_log"
  }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "status of phase 7")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Turn completes with no parent report (the Hi Bit missed-report shape).
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  fm_pending_reply_send_recovery "$state" "$corr" \
    || fail "recovery should send after completed turn + grace"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "phase should be recovery_sent, got $(phase_of "$state" "$corr")"
  [ -s "$hook_log" ] || fail "recovery hook should have been invoked once"
  # Second attempt must not re-send.
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "second recovery must refuse"
  fi
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "expected exactly one recovery send, got $lines"
  rec=$(fm_pending_reply_path "$state" "$corr")
  case "$(cat "$hook_log")" in
    *"corr=$corr"*) : ;;
    *) fail "recovery message must carry the original corr"$'\n'"$(cat "$hook_log")" ;;
  esac
  case "$(cat "$hook_log")" in
    *REPOST\ REQUIRED*) : ;;
    *) fail "recovery message must ask for a repost"$'\n'"$(cat "$hook_log")" ;;
  esac
  pass "completed turn with no report triggers exactly one recovery"
}

test_recovery_attempt_is_never_reinjected() {
  local home state corr rec hook_log lines live_corr live_rec live_pid live_identity
  home=$(setup_parent recovery-at-most-once)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-at-most-once.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=2500
  recovery_fail_hook() {
    printf 'attempted\n' >> "$hook_log"
    return 1
  }
  export -f recovery_fail_hook
  export FM_PENDING_REPLY_SEND_HOOK=recovery_fail_hook
  corr=$(fm_pending_reply_create "$home" "$state" hibit "at most once")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  if fm_pending_reply_send_recovery "$state" "$corr"; then
    fail "failed recovery transport should report failure"
  fi
  [ "$(phase_of "$state" "$corr")" = recovery_failed ] \
    || fail "failed recovery attempt should preserve failed delivery"
  [ -z "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" recovery_sent_epoch)" ] \
    || fail "failed recovery must not record a sent epoch"
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "committed recovery attempt must refuse reinjection"
  fi
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "recovery transport should be attempted once, got $lines"
  fm_pending_reply_maybe_escalate "$state" "$corr" \
    || fail "failed recovery delivery should escalate explicitly"
  grep -Fq "pending-reply-recovery-delivery-failed:" "$state/hibit.status" \
    || fail "failed recovery escalation should name delivery failure"
  live_corr=$(fm_pending_reply_create "$home" "$state" hibit "live recovery")
  fm_pending_reply_mark_delivered "$state" "$live_corr"
  fm_pending_reply_mark_turn_completed "$state" "$live_corr" request
  live_rec=$(fm_pending_reply_path "$state" "$live_corr")
  live_pid=${BASHPID:-$$}
  live_identity=$(fm_pending_reply_pid_identity "$live_pid") \
    || fail "live sender identity should be observable"
  fm_pending_reply_set "$live_rec" recovery_attempted_epoch 2500 || fail "live attempt precommit failed"
  fm_pending_reply_set "$live_rec" recovery_sender_pid "$live_pid" || fail "live sender pid commit failed"
  fm_pending_reply_set "$live_rec" recovery_sender_identity "$live_identity" \
    || fail "live sender identity commit failed"
  fm_pending_reply_set "$live_rec" phase recovery_sending || fail "live sending phase failed"
  fm_pending_reply_tick_one "$state" "$live_corr" unknown || fail "live recovery tick failed"
  [ "$(phase_of "$state" "$live_corr")" = recovery_sending ] \
    || fail "live recovery must remain in progress without elapsed-time inference"
  corr=$(fm_pending_reply_create "$home" "$state" hibit "crashed recovery")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" recovery_attempted_epoch 2500 || fail "attempt precommit failed"
  fm_pending_reply_set "$rec" phase recovery_sending || fail "sending phase precommit failed"
  fm_pending_reply_tick_one "$state" "$corr" unknown || fail "recovery reconciliation failed"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "interrupted recovery attempt should escalate unknown delivery"
  [ "$(fm_pending_reply_get "$rec" recovery_delivery_outcome)" = unknown ] \
    || fail "interrupted recovery should preserve unknown delivery outcome"
  [ -z "$(fm_pending_reply_get "$rec" recovery_sent_epoch)" ] \
    || fail "unknown recovery must not record a sent epoch"
  grep -Fq "pending-reply-recovery-delivery-unknown:" "$state/hibit.status" \
    || fail "unknown recovery escalation should name delivery uncertainty"
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "reconciliation must not call recovery transport, got $lines attempts"
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "recovery attempts reconcile without reinjection"
}

test_recovery_reply_resolves_original() {
  local home state corr hook_log
  home=$(setup_parent recovery-resolve)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-resolve-hook.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf '%s\n' "$2" >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=3000

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "phase 7 status")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  printf 'done [corr=%s]: phase 7 is Done (reposted)\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "recovery reply should resolve original"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "expected resolved after recovery reply"
  pass "recovery reply resolves the original expectation"
}

test_second_missed_turn_escalates_once_and_stays_durable() {
  local home state corr hook_log rec status_line escalations
  home=$(setup_parent escalate-once)
  state="$home/state"
  hook_log="$TMP_ROOT/escalate-hook.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf '%s\n' ok >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=4000
  # Do not export STATE into the test process: fm-send resolves
  # FM_STATE_OVERRIDE/STATE from the environment and a leak breaks later cases.

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "why is phase 7 stuck")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  # Recovery turn also completes with no correlated report.
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase should be escalated"
  status_line=$(tail -1 "$state/hibit.status")
  case "$status_line" in
    "blocked [key=pending-reply-$corr]:"*pending-reply-missed:*pending-reply-id=$corr*) : ;;
    *) fail "parent status should carry one blocked missed-report line"$'\n'"$status_line" ;;
  esac
  [ ! -s "$state/.wake-queue" ] || fail "direct escalation must not enqueue a duplicate check wake"
  # Second escalate must be a no-op (phase no longer recovery_sent).
  if fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null; then
    # Function returns 1 when phase is not recovery_sent - good.
    :
  fi
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase must stay escalated"
  escalations=$(grep -Fc "blocked [key=pending-reply-$corr]:" "$state/hibit.status")
  [ "$escalations" = 1 ] || fail "missed recovery should publish one escalation, got $escalations"
  # Durable record retained (never silently expired).
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || fail "escalated record must remain on disk"
  [ "$(fm_pending_reply_get "$rec" parent_status)" = "$state/hibit.status" ] \
    || fail "parent destination must remain exact"
  # Unrelated status activity still does not resolve.
  printf 'working: unrelated churn\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "unrelated status must not resolve an escalated miss"
  fi
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "must remain escalated after unrelated status"
  pass "second missed turn escalates once and remains durable"
}

# Wake-gate helpers reading the production seen-signature owner directly, so
# these assertions consume the exact gate the watcher's signal scan uses.
seen_gate() {  # <state> <file>: 0 when every byte is already announced
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_signal_seen_current "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}
prime_seen() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"; fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

test_escalation_wakes_and_its_close_stays_quiet() {
  local home state corr
  home=$(setup_parent escalation-wake-gate)
  state="$home/state"
  export FM_PENDING_REPLY_SEND_HOOK='true'
  export FM_PENDING_REPLY_NOW=4200
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "confirm the notarization")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  : > "$state/hibit.status"
  prime_seen "$state" "$state/hibit.status" || fail "could not prime the announced baseline"
  # A NEW blocker must wake: the escalation append leaves unannounced bytes.
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
  if seen_gate "$state" "$state/hibit.status"; then
    fail "a new pending-reply escalation was hidden from the watcher's signal gate"
  fi
  prime_seen "$state" "$state/hibit.status" || fail "could not mark the escalation announced"
  # A genuinely new correlated reply must wake too.
  printf 'done [corr=%s]: notarization confirmed\n' "$corr" >> "$state/hibit.status"
  if seen_gate "$state" "$state/hibit.status"; then
    fail "a new correlated reply was hidden from the watcher's signal gate"
  fi
  prime_seen "$state" "$state/hibit.status" || fail "could not mark the reply announced"
  # The home's own escalation CLOSE is bookkeeping and stays quiet.
  fm_pending_reply_try_resolve "$state" "$corr" || fail "correlated reply should resolve"
  grep -Fq "resolved [key=pending-reply-$corr]" "$state/hibit.status" \
    || fail "resolution did not close the escalation decision"
  seen_gate "$state" "$state/hibit.status" \
    || fail "the home's own escalation close re-woke its own watcher gate"
  pass "escalations and replies wake; the home's own escalation close stays quiet"
}

test_escalation_publication_failure_retries() {
  local home state corr rec target escalations
  home=$(setup_parent escalation-retry)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4500
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "retry escalation")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  export FM_PENDING_REPLY_SEND_HOOK='true'
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  rec=$(fm_pending_reply_path "$state" "$corr")
  target="$state/escalation-target"
  mkdir -p "$target"
  fm_pending_reply_set "$rec" parent_status "$target" || fail "failed to set escalation target"
  if fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null; then
    fail "escalation should fail when its durable status cannot be written"
  fi
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "publication failure must leave escalation retryable"
  rmdir "$target"
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation retry should succeed"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "successful retry should commit escalation"
  escalations=$(grep -Fc "blocked [key=pending-reply-$corr]:" "$target")
  [ "$escalations" = 1 ] || fail "successful retry should publish exactly once, got $escalations"
  pass "failed escalation publication remains retryable and publishes once"
}

test_legacy_escalation_closes_default_decision() {
  local home state corr rec open
  home=$(setup_parent legacy-close)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4725
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "legacy close")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase escalated
  fm_pending_reply_set "$rec" escalated_epoch 4700
  printf 'blocked: pending-reply-missed: task=hibit pending-reply-id=%s request=legacy close\n' "$corr" \
    > "$state/hibit.status"
  printf 'done [corr=%s]: delayed legacy reply\n' "$corr" >> "$state/hibit.status"

  fm_pending_reply_try_resolve "$state" "$corr" || fail "legacy reply should resolve its record"
  [ "$(grep -Fc "resolved [key=default]: pending-reply-resolved: task=hibit pending-reply-id=$corr" "$state/hibit.status")" -eq 1 ] \
    || fail "legacy escalation did not append one guarded default-key resolution"
  open=$(status_open_decisions "$state/hibit.status")
  [ -z "$open" ] || fail "resolved legacy escalation remained open: $open"
  [ -n "$(fm_pending_reply_get "$rec" escalation_closed_epoch)" ] \
    || fail "legacy escalation closure was not recorded"
  pass "legacy escalation closes under the shared default key"
}


test_normal_correlated_reply_resolves_once
test_completed_turn_no_report_triggers_one_recovery
test_recovery_attempt_is_never_reinjected
test_recovery_reply_resolves_original
test_second_missed_turn_escalates_once_and_stays_durable
test_escalation_wakes_and_its_close_stays_quiet
test_escalation_publication_failure_retries
test_legacy_escalation_closes_default_decision
