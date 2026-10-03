#!/usr/bin/env bash
# Shared-worker reconciliation across a service restart (issue #1 "Detach, TUI
# exit, server death"; review finding F5-B1).
#
# shuvcode keeps a durable execution claim for a turn in progress and its
# managed server resumes suspended sessions at boot, so a worker whose recorded
# service incarnation is gone may still be executing in the successor at the
# same frozen endpoint. bin/fm-opencode-v2-session.mjs is the one decision owner
# for teardown (teardown, or discard under --force), control interrupt and the
# descendant preflight (status); these cases drive its CLI.
#
# The stand-in service keeps execution claims in durable case data, so a
# successor started at the same endpoint (a real process restart that replaces
# the managed registration) reports the predecessor's turn as running. Every
# native call is logged with the answering service's pid.
#
# Contract asserted:
#   - same incarnation (positive control): status reports executing, teardown
#     refuses, interrupt cancels the exact session with resume=false;
#   - gone incarnation with a live successor: the successor's answer decides;
#     an executing session is never reported stopped, teardown refuses, and
#     interrupt cancels it on the successor with resume=false; once that
#     cancellation is confirmed, ordinary teardown succeeds. For an idle
#     successor session, shuvcode documents interrupting an idle session as a
#     no-op rather than a terminal release of a durable claim, so an
#     interrupted:false answer is not cancellation proof: ordinary teardown
#     refuses naming a retry or --force, always after consulting the successor,
#     and an explicit discard proceeds with the caveat;
#   - gone incarnation with no live successor: status may only answer an honest
#     unknown (executing null, cancellation unconfirmed), never "stopped";
#     teardown and interrupt refuse with a diagnostic naming the possible
#     resume; only discard (explicit --force) proceeds, printing that caveat.
# Any native interrupt anywhere must target the exact session with resume=false.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-worker-restart-acceptance)
export NODE_NO_WARNINGS=1
SESSION_HELPER="$V2_CODE_ROOT/bin/fm-opencode-v2-session.mjs"
SID=ses_worker_restart

# One case: a service at a stable endpoint, a worker session with a location
# and model, and its private worker record bound to that service incarnation.
worker_case() {  # <case>
  CASE="$TMP_ROOT/$1"
  v2_namespace "$1"
  mkdir -p "$CASE/wt" "$CASE/records"
  chmod 700 "$CASE/records"
  WT=$(cd -P "$CASE/wt" && pwd -P)
  RECORD="$CASE/records/worker.opencode-v2-session.json"
  v2_start_service "$CASE"
  FIRST_SERVICE=$V2_SERVICE_PID
  v2_session "$CASE" "$SID" "$WT"
  jq --arg id "$SID" '.[$id].model = {providerID: "mock", id: "echo"}' "$CASE/sessions.json" > "$CASE/sessions.tmp" \
    && mv "$CASE/sessions.tmp" "$CASE/sessions.json"
  printf '{}' > "$CASE/execution.json"
  : > "$CASE/api.log"
  RECORD="$RECORD" WT="$WT" SID="$SID" V2_SERVICE_PID="$V2_SERVICE_PID" "$V2_NODE_BIN" --input-type=module -e '
    const owner = await import(process.env.V2_CODE_ROOT_URL);
    const service = owner.identity(Number(process.env.V2_SERVICE_PID));
    owner.writePrivate(process.env.RECORD, { version: 1, sessionID: process.env.SID, location: { directory: process.env.WT },
      model: { providerID: "mock", id: "echo" }, servicePID: service.pid, serviceStart: service.start, hostBootID: service.boot,
      serviceURL: process.env.V2_SERVICE_URL });' \
    || fail "fixture: could not write the worker record"
}
V2_CODE_ROOT_URL="file://$V2_CODE_ROOT/bin/fm-opencode-v2-owner.mjs"
export V2_CODE_ROOT_URL

executing_turn() { jq -nc --arg id "$SID" '{($id): true}' > "$CASE/execution.json"; }
still_executing() { jq -e --arg id "$SID" 'has($id)' "$CASE/execution.json" >/dev/null; }

# Stop the recorded service; optionally start its successor at the same endpoint.
stop_first_service() {
  kill "$FIRST_SERVICE" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$FIRST_SERVICE" 2>/dev/null || return 0; sleep 0.1; done
  fail "fixture: the first service incarnation did not stop"
}
restart_at_same_endpoint() {
  stop_first_service
  v2_start_service "$CASE"
  SUCCESSOR=$V2_SERVICE_PID
  [ "$SUCCESSOR" != "$FIRST_SERVICE" ] && [ "$(jq -r .url "$V2_NATIVE_STATE/service.json")" = "$V2_SERVICE_URL" ] \
    || fail "fixture: the successor did not replace the registration at the same endpoint"
}

# Run one reconciliation action; sets RC, OUT, ERR.
reconcile() {  # <action>
  local out="$CASE/out.$1" err="$CASE/err.$1"
  PATH="$V2_NATIVE_BIN:$PATH" "$V2_NODE_BIN" "$SESSION_HELPER" "$1" "$RECORD" "$WT" > "$out" 2> "$err"
  RC=$?
  OUT=$(cat "$out")
  ERR=$(cat "$err")
}

# Every logged interrupt targets the exact session with resume=false.
interrupts_exact() { ! grep " session.interrupt " "$CASE/api.log" | grep -qv "sessionID=$SID.*resume=false"; }

api_calls() {  # <service-pid> <operation>: calls that service answered for the exact session
  grep -c "^$1 $2 .*sessionID=$SID" "$CASE/api.log" 2>/dev/null || true
}

# Collect every contract miss in one case so a red run names them all.
MISSES=()
miss() { MISSES+=("$1"); }
finish() {  # <pass-text>
  if [ "${#MISSES[@]}" -gt 0 ]; then
    local m=("${MISSES[@]}")
    MISSES=()
    fail "$(printf '%s; ' "${m[@]}")"
  fi
  pass "$1"
}

test_same_incarnation_control() {
  v2_require_native same-incarnation || return $?
  worker_case same-incarnation
  executing_turn
  reconcile status
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == true' >/dev/null; } || miss "status did not report the executing worker: rc=$RC out=$OUT err=$ERR"
  reconcile teardown
  [ "$RC" != 0 ] || miss "teardown accepted an executing worker: $OUT"
  still_executing || miss "teardown changed execution"
  reconcile interrupt
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == false' >/dev/null; } || miss "interrupt did not stop the worker: rc=$RC out=$OUT err=$ERR"
  grep -q "^$FIRST_SERVICE session.interrupt .*sessionID=$SID.*resume=false" "$CASE/api.log" || miss "interrupt did not cancel the exact session with resume=false"
  ! still_executing || miss "the worker still executes after interrupt"
  finish "worker restart: same incarnation reports executing, refuses teardown and interrupts the exact session with resume=false"
}

test_successor_resumes_executing_worker() {
  v2_require_native successor-executing || return $?
  worker_case successor-executing
  executing_turn
  restart_at_same_endpoint
  reconcile status
  if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == false' >/dev/null; then
    miss "status reported a resumed worker as stopped ($OUT)"
  elif [ "$RC" != 0 ]; then
    miss "status could not read the successor: rc=$RC err=$ERR"
  fi
  [ "$(api_calls "$SUCCESSOR" session.get)" -ge 1 ] || miss "the live successor was never consulted for the exact session"
  reconcile teardown
  [ "$RC" != 0 ] || miss "teardown accepted a worker the successor is still executing ($OUT)"
  still_executing || miss "teardown changed execution"
  reconcile interrupt
  [ "$(grep -c "^$SUCCESSOR session.interrupt .*sessionID=$SID.*resume=false" "$CASE/api.log")" -ge 1 ] \
    || miss "interrupt did not cancel the exact session on the successor with resume=false (rc=$RC out=$OUT)"
  ! still_executing || miss "the worker still executes on the successor after an interrupt reported $OUT"
  # After a confirmed cancellation the ordinary cleanup must be able to finish.
  reconcile teardown
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == false' >/dev/null; } \
    || miss "ordinary teardown still refused after the successor confirmed cancellation: rc=$RC err=$ERR"
  interrupts_exact || miss "an interrupt did not target the exact session with resume=false"
  finish "worker restart: a live successor's resumed turn is reported executing, refuses teardown, is interrupted there with resume=false, then tears down"
}

test_successor_idle_needs_proof_or_discard() {
  v2_require_native successor-idle || return $?
  worker_case successor-idle
  restart_at_same_endpoint
  reconcile status
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == false' >/dev/null; } || miss "status did not report the successor's idle answer: rc=$RC out=$OUT err=$ERR"
  [ "$(api_calls "$SUCCESSOR" session.get)" -ge 1 ] || miss "status concluded without consulting the live successor"
  reconcile teardown
  if [ "$RC" = 0 ]; then
    miss "ordinary teardown accepted an idle interrupt answer as cancellation proof ($OUT)"
  elif ! printf '%s' "$ERR" | grep -qiE 'retry|--force'; then
    miss "the idle-successor refusal names neither a retry nor --force: $ERR"
  fi
  interrupts_exact || miss "an interrupt did not target the exact session with resume=false"
  reconcile discard
  [ "$RC" = 0 ] || miss "explicit discard was refused for an idle successor session: $ERR"
  printf '%s' "$ERR$OUT" | grep -qiE 'resume|unconfirmed' || miss "discard printed no caveat that cancellation is unconfirmed"
  finish "worker restart: an idle successor answer refuses ordinary teardown without terminal proof (retry or --force), and an explicit discard proceeds with the caveat"
}

no_successor_case() {  # <case> <stop|unregister>
  worker_case "$1"
  executing_turn
  stop_first_service
  [ "$2" = stop ] || rm -f "$V2_NATIVE_STATE/service.json"
  local action
  # status is read-only: it may answer, but only an honest unknown.
  reconcile status
  if [ "$RC" = 0 ]; then
    printf '%s' "$OUT" | jq -e '.executing == null and .cancellation == "unconfirmed"' >/dev/null \
      || miss "status answered something other than an honest unknown without any live service ($OUT)"
  fi
  for action in teardown interrupt; do
    reconcile "$action"
    if [ "$RC" = 0 ]; then
      miss "$action concluded without any live service ($OUT)"
    elif ! printf '%s' "$ERR" | grep -qiE 'resume|restart|start the service'; then
      miss "$action refused without naming the possible resume: $ERR"
    fi
  done
  [ ! -s "$CASE/api.log" ] || miss "a refusal queried or interrupted a service: $(tr '\n' ';' < "$CASE/api.log")"
  reconcile discard
  [ "$RC" = 0 ] || miss "explicit discard was refused: $ERR"
  printf '%s' "$ERR$OUT" | grep -qiE 'resume|orphan' || miss "discard printed no caveat that the orphaned turn may resume"
}

test_no_successor_refuses_unless_discarded() {
  v2_require_native no-successor || return $?
  no_successor_case no-successor stop
  finish "worker restart: with the service down, status answers only an honest unknown, teardown and interrupt refuse naming the possible resume, and discard proceeds with the caveat"
}

test_unregistered_endpoint_refuses_unless_discarded() {
  v2_require_native no-registration || return $?
  no_successor_case no-registration unregister
  finish "worker restart: with no registration at the frozen endpoint, only an explicit discard proceeds, with the caveat"
}

v2_run_cases \
  test_same_incarnation_control \
  test_successor_resumes_executing_worker \
  test_successor_idle_needs_proof_or_discard \
  test_no_successor_refuses_unless_discarded \
  test_unregistered_endpoint_refuses_unless_discarded
