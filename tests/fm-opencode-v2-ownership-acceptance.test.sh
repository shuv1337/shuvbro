#!/usr/bin/env bash
# Lead ownership acceptance for OpenCode V2 on the shared service (issue #1;
# frozen contract: immutable exact-session activation, bare-PID .lock plus the
# supplemental exact proof, frozen external paths, no observer takeover).
#
# Model shells run inside the service stand-in, so their /proc ancestry is the
# registered execution service exactly as on the real host. Registrations are
# real claims by a live owner stand-in, with root equal to the production code
# root so a positive lock case can only fail for product reasons. The
# production bin/fm-lock.sh and owner helper run from that code root.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-ownership-acceptance)
export NODE_NO_WARNINGS=1

registered() {  # <case> [session]: sets CASE HOME_DIR V2_*
  local session=${2:-ses_lead}
  CASE="$TMP_ROOT/$1"
  v2_namespace "$1"
  HOME_DIR=$(v2_make_home "$CASE/home-$session")
  [ -n "${V2_SOCKET:-}" ] && [ "${KEEP_SERVICE:-0}" = 1 ] || v2_start_service "$CASE"
  v2_session "$CASE" "$session" "$V2_CODE_ROOT"
  v2_register "$CASE" "$session" "$V2_CODE_ROOT" "$HOME_DIR"
  v2_session "$CASE" "$session" "$V2_CODE_ROOT" "" "$session" "$V2_CLAIM"
}

lock_in_shell() {  # <session> <home> [extra-env-override-json]
  local env
  env=$(v2_lead_env "$2")
  [ -z "${3:-}" ] || env=$(jq -nc --argjson a "$env" --argjson b "$3" '$a + $b')
  v2_shell "$1" 'bash bin/fm-lock.sh' "$env"
}

helper_in_shell() {  # <session> <home> <command-prefix>
  v2_shell "$1" "$3 node bin/fm-opencode-v2-owner.mjs helper \"\$FM_STATE_OVERRIDE\"" "$(v2_lead_env "$2")"
}

test_registered_lead_shell_acquires_for_owner() {
  v2_require_native registered-lock || return $?
  registered registered-lock
  local out
  out=$(lock_in_shell ses_lead "$HOME_DIR")
  printf '%s' "$out" | jq -e '.code == 0' >/dev/null || fail "the registered lead's model shell could not acquire its home lock: $out"
  [ "$(cat "$HOME_DIR/state/.lock")" = "$V2_OWNER_PID" ] || fail ".lock does not name the live owner pid $V2_OWNER_PID: $(cat "$HOME_DIR/state/.lock")"
  out=$(helper_in_shell ses_lead "$HOME_DIR" "")
  printf '%s' "$out" | jq -e --arg p "$V2_OWNER_PID" '.code == 0 and (.stdout | test($p))' >/dev/null \
    || fail "after acquisition the lead shell's helper proof failed: $out"
  pass "ownership: the registered lead's model shell acquires .lock for the live owner and passes the helper proof"
}

test_unregistered_session_is_refused() {
  v2_require_native unregistered || return $?
  registered unregistered
  lock_in_shell ses_lead "$HOME_DIR" | jq -e '.code == 0' >/dev/null || fail "positive control: the lead could not lock"
  v2_session "$CASE" ses_other "$V2_CODE_ROOT"
  local out
  out=$(lock_in_shell ses_other "$HOME_DIR")
  printf '%s' "$out" | jq -e '.code != 0' >/dev/null || fail "another session on the same service took the lead's home lock: $out"
  [ "$(cat "$HOME_DIR/state/.lock")" = "$V2_OWNER_PID" ] || fail "the refused session changed .lock"
  pass "ownership: another session on the same service is refused the registered lead's home lock"
}

test_shell_without_session_identity_never_locks() {
  v2_require_native no-session-identity || return $?
  registered no-session-identity
  local out
  out=$(v2_shell ses_lead 'unset OPENCODE_SESSION_ID; bash bin/fm-lock.sh' "$(v2_lead_env "$HOME_DIR")")
  printf '%s' "$out" | jq -e '.code != 0' >/dev/null || fail "a service shell with no session identity acquired the home lock: $out"
  [ ! -s "$HOME_DIR/state/.lock" ] || fail "a shell with no session identity wrote .lock: $(cat "$HOME_DIR/state/.lock")"
  lock_in_shell ses_lead "$HOME_DIR" | jq -e '.code == 0' >/dev/null || fail "positive control: the lead could not lock afterwards"
  [ "$(cat "$HOME_DIR/state/.lock")" != "$V2_SERVICE_PID" ] || fail "the service pid was recorded as the lock holder"
  pass "ownership: a service shell without a session id never locks; the lead then locks for its owner, never the service pid"
}

# M2: a non-lead shell on the same service that exports the lead's session id
# and paths must not gain the lead's helper authority.
test_spoofed_session_id_gains_no_authority() {
  v2_require_native spoofed-session || return $?
  registered spoofed-session
  lock_in_shell ses_lead "$HOME_DIR" | jq -e '.code == 0' >/dev/null || fail "positive control: the lead could not lock"
  v2_session "$CASE" ses_worker "$V2_CODE_ROOT"
  local out
  out=$(helper_in_shell ses_worker "$HOME_DIR" "export OPENCODE_SESSION_ID=ses_lead;")
  printf '%s' "$out" | jq -e '.code != 0' >/dev/null \
    || fail "a worker shell on the shared service gained the lead's helper authority by exporting its session id: $out"
  pass "ownership: exporting the lead's session id from another service shell gains no lead helper authority"
}

test_overwritten_environment_is_refused_with_diagnostic() {
  v2_require_native env-overwrite || return $?
  registered env-overwrite
  local other out
  other=$(v2_make_home "$CASE/other-home")
  out=$(lock_in_shell ses_lead "$HOME_DIR" "$(jq -nc --arg h "$other" '{FM_HOME: $h, FM_STATE_OVERRIDE: ($h + "/state"), FM_CONFIG_OVERRIDE: ($h + "/config")}')")
  printf '%s' "$out" | jq -e '.code != 0' >/dev/null || fail "an overwritten shell environment acquired a lock: $out"
  [ ! -s "$other/state/.lock" ] || fail "an overwritten environment rebound ownership to another home"
  out=$(v2_shell ses_lead "node bin/fm-opencode-v2-owner.mjs helper '$other/state'" \
    "$(jq -nc --arg r "$V2_CODE_ROOT" --arg h "$other" --arg ns "$FM_V2_REGISTRY_NAMESPACE" '{FM_ROOT_OVERRIDE: $r, FM_HOME: $h, FM_STATE_OVERRIDE: ($h + "/state"), FM_CONFIG_OVERRIDE: ($h + "/config"), FM_V2_REGISTRY_NAMESPACE: $ns}')")
  printf '%s' "$out" | jq -e '.stderr | test("environment")' >/dev/null \
    || fail "the refusal did not name the environment replacement: $out"
  lock_in_shell ses_lead "$HOME_DIR" | jq -e '.code == 0' >/dev/null || fail "divergence lost: the frozen environment was refused too"
  pass "ownership: an overwritten shell environment is refused with an environment diagnostic, the frozen one acquires"
}

test_new_service_incarnation_refuses_lock() {
  v2_require_native service-restart-negative || return $?
  registered service-restart-negative
  lock_in_shell ses_lead "$HOME_DIR" | jq -e '.code == 0' >/dev/null || fail "positive control: the lead could not lock"
  v2_start_service "$CASE"
  local out
  out=$(helper_in_shell ses_lead "$HOME_DIR" "")
  printf '%s' "$out" | jq -e '.code != 0' >/dev/null \
    || fail "a model shell under a new service incarnation passed the helper proof before republication: $out"
  pass "ownership: a new service incarnation refuses the helper proof until the owner republishes"
}

test_two_registered_homes_never_cross() {
  v2_require_native two-homes || return $?
  registered two-homes ses_a
  local home_a=$HOME_DIR out
  KEEP_SERVICE=1 registered two-homes ses_b
  local home_b=$HOME_DIR
  out=$(lock_in_shell ses_a "$home_b")
  printf '%s' "$out" | jq -e '.code != 0' >/dev/null || fail "lead A's shell acquired home B's lock: $out"
  lock_in_shell ses_a "$home_a" | jq -e '.code == 0' >/dev/null || fail "lead A could not lock its own home"
  lock_in_shell ses_b "$home_b" | jq -e '.code == 0' >/dev/null || fail "lead B could not lock its own home beside lead A"
  pass "ownership: two homes registered on one service each lock only their own home"
}

test_second_claim_on_live_session_is_refused() {
  v2_require_native observer-claim || return $?
  registered observer-claim
  local first=$V2_OWNER_PID out
  out="$CASE/second-owner.out"
  "$V2_NODE_BIN" "$V2_HARNESS" owner "$V2_CODE_ROOT" "$V2_SOCKET" ses_lead "$V2_CODE_ROOT" "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/config" > "$out" 2>&1 &
  v2_track $!
  sleep 2
  grep -q 'conflicting live V2 claim\|observer cannot take over' "$out" \
    || fail "a second owner's claim on a live lead was not refused as an observer: $(cat "$out")"
  [ "$("$V2_NODE_BIN" "$V2_CODE_ROOT/bin/fm-opencode-v2-owner.mjs" read ses_lead | jq -r .ownerPID)" = "$first" ] \
    || fail "the second claim replaced the live owner"
  pass "ownership: a second claim on a live lead is refused and the live owner keeps its registration"
}

v2_run_cases \
  test_registered_lead_shell_acquires_for_owner \
  test_unregistered_session_is_refused \
  test_shell_without_session_identity_never_locks \
  test_spoofed_session_id_gains_no_authority \
  test_overwritten_environment_is_refused_with_diagnostic \
  test_new_service_incarnation_refuses_lock \
  test_two_registered_homes_never_cross \
  test_second_claim_on_live_session_is_refused
