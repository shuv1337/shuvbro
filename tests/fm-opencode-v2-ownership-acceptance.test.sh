#!/usr/bin/env bash
# Lead ownership acceptance for OpenCode V2 on the shared service (issue #1;
# frozen contract: immutable exact-session activation, bare-PID .lock plus
# supplemental exact proof, frozen external paths, no observer takeover).
#
# Covered here through public interfaces:
#   - a registered lead's model shell acquires the home lock; another session
#     on the same service, an unregistered session, and a session whose shell
#     environment was overwritten by another client are refused;
#   - a service restart (new service incarnation) refuses until republication;
#   - two homes registered on one service never cross;
#   - activation copied into another process, or a worker environment, is inert;
#   - a second client for the same lead stays an observer.
# Cases needing a not-yet-published production interface report "pending"
# through tests/fm-opencode-v2-acceptance-lib.sh, never pass.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-ownership-acceptance)
NS=v2own$$
SERVICE=

start_service() {
  sleep 120 >/dev/null 2>&1 &
  SERVICE=$!
}
# Stops the stand-in service and every stand-in owner of this case.
stop_service() {
  local pid
  for pid in $SERVICE $OWNERS; do
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
  done
  SERVICE=
  OWNERS=
}

# A live stand-in for the activated TUI owner process.
OWNER=
OWNERS=
start_owner() {
  sleep 120 >/dev/null 2>&1 &
  OWNER=$!
  OWNERS="$OWNERS $OWNER"
}

registered_home() {  # <case> <dir> <session>
  local dir=$2
  v2_make_primary "$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/config"
  start_owner
  v2_register_lead "$1" "$NS" "$3" "$dir/root" "$dir/home" "$dir/home/state" "$dir/home/config" "$OWNER"
}

test_registered_lead_shell_acquires_and_other_session_is_refused() {
  local dir fakebin out status=0
  dir="$TMP_ROOT/registered"
  fakebin=$(fm_fakebin "$dir")
  v2_shared_service_ps "$fakebin"
  start_service
  registered_home registered-lock "$dir" ses_lead || { stop_service; return 3; }
  out=$(v2_lock_as_session "$dir/home" "$fakebin" "$SERVICE" ses_lead) || status=$?
  [ "$status" -eq 0 ] || { stop_service; fail "the registered lead's shell could not acquire its home lock: $out"; }
  [ "$(cat "$dir/home/state/.lock")" = "$OWNER" ] \
    || { stop_service; fail ".lock does not name the live TUI owner pid: $(cat "$dir/home/state/.lock")"; }
  status=0
  out=$(v2_lock_as_session "$dir/home" "$fakebin" "$SERVICE" ses_other) || status=$?
  stop_service
  [ "$status" -ne 0 ] || fail "another session on the same service acquired the registered lead's home lock: $out"
  pass "ownership: the registered lead's shell acquires the lock for its owner and another session is refused"
}

test_overwritten_shell_environment_is_refused() {
  local dir fakebin out status=0 other
  dir="$TMP_ROOT/env-overwrite"
  fakebin=$(fm_fakebin "$dir")
  v2_shared_service_ps "$fakebin"
  start_service
  registered_home env-overwrite "$dir" ses_lead || { stop_service; return 3; }
  other="$dir/other-home"
  mkdir -p "$other/state"
  # Another client focused the lead and replaced its session environment.
  out=$(v2_lock_as_session "$other" "$fakebin" "$SERVICE" ses_lead) || status=$?
  [ "$status" -ne 0 ] || { stop_service; fail "an overwritten shell FM_HOME acquired a lock: $out"; }
  [ ! -s "$other/state/.lock" ] || { stop_service; fail "an overwritten environment rebound ownership to another home"; }
  printf '%s' "$out" | grep -qi 'environment' \
    || { stop_service; fail "the refusal did not name the likely environment replacement: $out"; }
  status=0
  out=$(v2_lock_as_session "$dir/home" "$fakebin" "$SERVICE" ses_lead) || status=$?
  stop_service
  [ "$status" -eq 0 ] || fail "divergence lost: the frozen environment was also refused: $out"
  pass "ownership: a shell environment overwritten by another client is refused, the frozen one acquires"
}

test_service_restart_refuses_until_republished() {
  local dir fakebin out status=0 old
  dir="$TMP_ROOT/service-restart"
  fakebin=$(fm_fakebin "$dir")
  v2_shared_service_ps "$fakebin"
  start_service
  registered_home service-restart "$dir" ses_lead || { stop_service; return 3; }
  old=$SERVICE
  stop_service
  start_service
  [ "$SERVICE" != "$old" ] || { stop_service; fail "fixture vacuous: the replacement service reused the pid"; }
  out=$(v2_lock_as_session "$dir/home" "$fakebin" "$SERVICE" ses_lead) || status=$?
  stop_service
  [ "$status" -ne 0 ] || fail "a model shell under a new service incarnation acquired the lock before republication: $out"
  pass "ownership: a service restart refuses lock mutation until the owner republishes the new incarnation"
}

test_two_registered_homes_on_one_service_never_cross() {
  local dir fakebin out status=0
  dir="$TMP_ROOT/two-homes"
  fakebin=$(fm_fakebin "$dir")
  v2_shared_service_ps "$fakebin"
  start_service
  registered_home two-homes "$dir/a" ses_a || { stop_service; return 3; }
  registered_home two-homes "$dir/b" ses_b || { stop_service; return 3; }
  out=$(v2_lock_as_session "$dir/b/home" "$fakebin" "$SERVICE" ses_a) || status=$?
  [ "$status" -ne 0 ] || { stop_service; fail "lead A's shell acquired home B's lock: $out"; }
  status=0
  out=$(v2_lock_as_session "$dir/a/home" "$fakebin" "$SERVICE" ses_a) || status=$?
  [ "$status" -eq 0 ] || { stop_service; fail "lead A could not acquire its own home: $out"; }
  status=0
  out=$(v2_lock_as_session "$dir/b/home" "$fakebin" "$SERVICE" ses_b) || status=$?
  stop_service
  [ "$status" -eq 0 ] || fail "lead B could not acquire its own home beside lead A: $out"
  pass "ownership: two homes registered on one service each lock only their own home"
}

# Activation is valid only in the exact owner process. Loading the TUI entry
# in any other process with a copied activation must stay inert: no
# registration, no prompt, no arm. Needs the TUI entry and activation contract.
test_copied_activation_is_inert_in_another_process() {
  [ -n "${FM_V2_TEST_TUI_ENTRY:-}" ] || { v2_pending copied-activation "TUI entry path (FM_V2_TEST_TUI_ENTRY) and its client context driver"; return $?; }
  local activation rc=0
  activation=$(v2_activation_env copied-activation ses_lead "$$") || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$activation"; return "$rc"; }
  v2_pending copied-activation "TUI context driver for the published entry"
}

# A worker launched from the lead's shell (whose session environment carries
# the TUI-pushed activation) must not receive lead activation.
test_worker_launch_scrubs_activation() {
  local activation rc=0
  activation=$(v2_activation_env worker-scrub ses_lead "$$") || rc=$?
  [ "$rc" -eq 0 ] || { printf '%s\n' "$activation"; return "$rc"; }
  v2_pending worker-scrub "agreed observable for fm-spawn activation removal"
}

# A second client attached to the same lead is an immutable observer: it never
# publishes a registration, startup prompt or watcher, and never takes over
# after the owner exits.
test_second_client_is_an_observer() {
  [ -n "${FM_V2_TEST_TUI_ENTRY:-}" ] || { v2_pending second-client "TUI entry path (FM_V2_TEST_TUI_ENTRY) and its client context driver"; return $?; }
  v2_pending second-client "TUI context driver for the published entry"
}

v2_run_cases \
  test_registered_lead_shell_acquires_and_other_session_is_refused \
  test_overwritten_shell_environment_is_refused \
  test_service_restart_refuses_until_republished \
  test_two_registered_homes_on_one_service_never_cross \
  test_copied_activation_is_inert_in_another_process \
  test_worker_launch_scrubs_activation \
  test_second_client_is_an_observer
