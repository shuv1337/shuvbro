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
#     interrupted:false answer alone is not cancellation proof. Settlement
#     (review F8-M1) needs the successor past its 30 s bound, the session idle
#     in a second sample, and the newest message terminal: an idle notice of
#     any outcome (succeeded, failed, interrupted) or an assistant answer with
#     finish "stop" and no error, whenever that turn ended, including before
#     the restart. While unproven (young successor, session active again, a
#     newer user message, a tool-call step, a bare errored answer, an unknown
#     notice outcome) ordinary teardown refuses naming a retry or --force,
#     status reports the outcome as unknown, and the binding is unchanged;
#     once proven, ordinary teardown succeeds as settled (not interrupted) and
#     the binding moves to the proven successor. An explicit discard proceeds
#     with the caveat;
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
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == null and .observedExecuting == false and .incarnation == "successor" and .cancellation == "unproven"' >/dev/null; } \
    || miss "status did not report an idle but unproven successor outcome: rc=$RC out=$OUT err=$ERR"
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
  finish "worker restart: a young idle successor reports an unproven outcome and refuses ordinary teardown (retry or --force); an explicit discard proceeds with the caveat"
}

# Settlement proof against one successor that matures past the 30 s bound.
# The pre-settlement worker record is restored before each variant, so every
# variant is judged against the same restarted-successor binding.
now_ms() { date +%s%3N; }
assistant() {  # <completed-ms> [finish] [error]: an assistant message
  jq -nc --argjson c "$1" --arg f "${2:-stop}" --arg e "${3:-}" '{type: "assistant", finish: $f, time: {created: ($c - 500), completed: $c}} + (if $e == "" then {} else {error: {message: $e}} end)'
}
idle_notice() { jq -nc --argjson c "$1" --arg o "${2:-succeeded}" '{type: "idle", outcome: $o, time: {created: $c}}'; }
messages() { jq -s '.' > "$CASE/messages.json"; }  # newest first on stdin
binding() { sha256sum "$RECORD" | cut -d' ' -f1; }
restore_binding() { cp "$CASE/record.before" "$RECORD"; chmod 600 "$RECORD"; }
unproven_refusal() {  # <label>
  local before
  restore_binding
  before=$(binding)
  reconcile teardown
  if [ "$RC" = 0 ]; then
    miss "$1: ordinary teardown accepted settlement without proof ($OUT)"
  elif ! printf '%s' "$ERR" | grep -qiE 'retry|--force'; then
    miss "$1: refusal names neither a retry nor --force: $ERR"
  fi
  [ "$(binding)" = "$before" ] || miss "$1: an unproven refusal rewrote the worker binding"
}
proven_settlement() {  # <label>
  restore_binding
  reconcile teardown
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == false and .interrupted == false and .cancellation == "settled"' >/dev/null; } \
    || miss "$1: ordinary teardown refused a proven settled successor: rc=$RC out=$OUT err=$ERR"
  jq -e --argjson p "$SUCCESSOR" '.servicePID == $p' "$RECORD" >/dev/null || miss "$1: the binding did not move to the proven successor"
}

test_successor_settlement_proof() {
  v2_require_native successor-settlement || return $?
  worker_case successor-settlement
  local restarted mature before_restart after
  # The worker's last turn ended before the restart: a terminal answer and the
  # fork's succeeded idle notice, then the service restarts.
  before_restart=$(now_ms)
  { idle_notice "$((before_restart + 5))"; assistant "$before_restart"; } | messages
  sleep 0.3
  restart_at_same_endpoint
  restarted=$(now_ms)
  cp "$RECORD" "$CASE/record.before"
  unproven_refusal "young successor"
  mature=$((restarted / 1000 + 32))
  while [ "$(date +%s)" -lt "$mature" ]; do sleep 1; done
  after=$(now_ms)
  # Still unproven past the bound.
  { jq -nc --argjson c "$after" '{type: "user", time: {created: $c}}'; assistant "$before_restart"; } | messages
  unproven_refusal "a newer user message after the answer"
  { assistant "$after" tool-calls; } | messages
  unproven_refusal "a tool-call step as the newest message"
  { assistant "$after" stop "provider failed"; } | messages
  unproven_refusal "a bare errored answer as the newest message"
  { idle_notice "$after" running; } | messages
  unproven_refusal "an idle notice with an unknown outcome"
  { idle_notice "$((before_restart + 5))"; assistant "$before_restart"; } | messages
  printf 'idle\nrunning %s\nrunning %s\nrunning %s\n' "$SID" "$SID" "$SID" > "$CASE/active-samples"
  unproven_refusal "the session active again in the second sample"
  rm -f "$CASE/active-samples"
  interrupts_exact || miss "an interrupt did not target the exact session with resume=false"
  # Proven: any terminal outcome, whenever it ended.
  { idle_notice "$((before_restart + 5))"; assistant "$before_restart"; } | messages
  proven_settlement "a turn that ended before the restart (succeeded notice)"
  { assistant "$before_restart"; } | messages
  proven_settlement "a bare stop answer completed before the restart"
  { idle_notice "$after" failed; assistant "$after" stop "provider failed"; } | messages
  proven_settlement "a failed idle notice"
  { idle_notice "$after" interrupted; } | messages
  proven_settlement "an interrupted idle notice"
  # After the binding moved, later ordinary teardown succeeds.
  reconcile teardown
  { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.executing == false' >/dev/null; } || miss "ordinary teardown refused after the binding moved: rc=$RC err=$ERR"
  finish "worker restart: an idle successor settles only past its bound, idle across samples, with a terminal newest message of any outcome (including a turn that ended before the restart); each unproven variant refuses unchanged"
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
  test_successor_settlement_proof \
  test_no_successor_refuses_unless_discarded \
  test_unregistered_endpoint_refuses_unless_discarded
