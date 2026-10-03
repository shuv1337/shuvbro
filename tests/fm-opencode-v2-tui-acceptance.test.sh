#!/usr/bin/env bash
# TUI owner acceptance for OpenCode V2 on the shared service (issue #1 rows
# "New lead session", "Attach/resume", "Two homes", "Two clients", "Busy lead
# receives actionable wake", "Watcher and turn-end race", "SSE gap", "Detach,
# TUI exit, server death"; review findings B1, B2, M1, M3, M5, M7, TM2-TM4).
#
# The production TUI entry runs under a genuine activation for the driver's own
# process (tests/assets/fm-opencode-v2-native-harness.mjs `tui`), against a
# service stand-in that parents model shells and hosts the production server
# entry's bindingStatus. The production coordinator drives the real
# fm-watch-arm.sh / fm-watch.sh / fm-wake-drain.sh recovery helpers in a
# disposable home; only native prompt admission is faked.
#
# Transitions are awaited with bounded readiness polls (harness `wait` steps),
# not wall-clock sleeps; a fixed window is used only to assert that something
# did NOT happen. Cases that must tell an event-triggered reconcile from the
# periodic fallback run the TUI's 2 s reconcile timer on a manual clock.
#
# Lead model shells that are not themselves testing environment replacement
# (B2) pass PATH explicitly, so a B2 failure cannot mask the case under test.
set -u

# Spawn-world fixtures first: sourcing them re-installs tests/lib.sh's EXIT trap,
# which the acceptance library then extends with its own teardown.
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-tui-acceptance)
export NODE_NO_WARNINGS=1
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
WAKE='WATCHER FIRED'

# One case directory with a service, an external home and a lead session.
tui_case() {  # <case> [supervision-needed:0|1] [session]
  local session=${3:-ses_lead}
  CASE="$TMP_ROOT/$1"
  v2_namespace "$1"
  HOME_DIR=$(v2_make_home "$CASE/home-$session")
  mkdir -p "$HOME_DIR/data"
  # Supervision need comes from the canonical owner (fm-supervision-lib): one
  # in-flight task record. It names no endpoint, so the watcher raises no
  # stale or missing-endpoint wakes for it.
  [ "${2:-0}" = 0 ] || printf 'kind=ship\n' > "$HOME_DIR/state/t1.meta"
  [ -n "${V2_SOCKET:-}" ] && [ "${KEEP_SERVICE:-0}" = 1 ] || v2_start_service "$CASE"
  v2_session "$CASE" "$session" "$V2_CODE_ROOT"
}

spec() {  # <extra-json> [session]
  jq -nc --arg r "$V2_CODE_ROOT" --arg h "$HOME_DIR" --arg pf "$V2_STATE_DIR/pids" --arg s "${2:-ses_lead}" --argjson x "${1:-{\}}" \
    '{sessionID: $s, root: $r, home: $h, state: ($h + "/state"), config: ($h + "/config"), pidsFile: $pf, markerFile: ($h + "/state/.watcher-down")} + $x'
}

lead_env_with_path() {
  jq -nc --argjson e "$(v2_lead_env "$HOME_DIR")" --arg p "$PATH" '$e + {PATH: $p}'
}

# Steps shared by most cases: the lead model shell acquires .lock (the
# canonical session start's ownership step), then the owner arms.
lock_step() { jq -nc --argjson e "$(lead_env_with_path)" '{do: "shell", command: "bash bin/fm-lock.sh", extraEnv: $e}'; }
helper_step() { jq -nc --argjson p "{\"PATH\":\"$PATH\"}" '{do: "shell", command: "node bin/fm-opencode-v2-owner.mjs helper \"$FM_STATE_OVERRIDE\"", extraEnv: $p}'; }
owned_and_armed() {  # <lock-step-json>: steps until the owner holds .lock and a watcher is live
  jq -nc --argjson l "$1" '[{do: "wait", until: "admitted", match: "fm-session-start"}, $l, {do: "wait", until: "lock"}, {do: "wait", until: "watcher"}]'
}
# Count fm-watch.sh processes serving this home (singleton evidence).
watchers_step() {
  jq -nc --arg s "$HOME_DIR/state" '{do: "shell", command: ("n=0; for p in $(pgrep -f \"/bin/fm-watch\\\\.sh( |$)\"); do tr \"\\\\0\" \"\\\\n\" < /proc/$p/environ 2>/dev/null | grep -qx \"FM_STATE_OVERRIDE=" + $s + "\" && n=$((n+1)); done; echo watchers=$n")}'
}

startup_admissions() { jq '[.admitted[] | select(.text | test("fm-session-start"))] | length' "$1"; }
wake_admissions() { jq --arg w "$WAKE" '[.admitted[] | select(.text | test($w))] | length' "$1"; }
wake_prompts() { jq -c --arg w "$WAKE" '[.prompts[] | select(.text | test($w))]' "$1"; }
step_ok() {  # <out> <index> <label>
  jq -e --argjson i "$2" '.steps[$i].ok == true' "$1" >/dev/null || fail "$3: $(jq -c --argjson i "$2" '{step: .steps[$i], failures}' "$1")"
}

# --- activation, inertness, reload --------------------------------------------

# Positive control for everything below: activation publishes the claim and
# marker, proves the service, pushes routing, and admits one startup nudge,
# with no session.created or idle event ever delivered (quiet exact-id attach).
test_activation_publishes_and_nudges_once_without_events() {
  v2_require_native activation || return $?
  tui_case activation
  local out="$CASE/out.json"
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"wait","until":"admitted","match":"fm-session-start"},{"do":"registration"}]}')" "$out"
  jq -e '.setup == "ok"' "$out" >/dev/null || fail "activated setup did not complete: $(jq -c '{setup, failures}' "$out")"
  step_ok "$out" 0 "the startup nudge was never admitted"
  [ "$(startup_admissions "$out")" = 1 ] || fail "expected exactly one startup nudge admission: $(jq -c '.admitted' "$out")"
  jq -e '.admitted[0].id | startswith("msg_")' "$out" >/dev/null || fail "startup admission carried no stable message id"
  jq -e '.admitted[0].delivery == "queue"' "$out" >/dev/null || fail "startup admission was not explicitly queued"
  jq -e --arg c "$(jq -r .claimID "$out")" '.steps[1].record.claimID == $c' "$out" >/dev/null \
    || fail "the activation's exact claim was not registered: $(jq -c '.steps[1]' "$out")"
  jq -e --arg c "$(jq -r .claimID "$out")" '.firstmateV2Lead.claimID == $c and .firstmateV2Lead.sessionID == "ses_lead"' \
    <(jq '.ses_lead.metadata' "$CASE/sessions.json") >/dev/null || fail "the exact lead marker was not written: $(cat "$CASE/sessions.json")"
  pass "tui: activation registers the exact claim and marker and admits one queued startup nudge with no session events"
}

test_inactive_tui_stays_inert() {
  v2_require_native inactive || return $?
  tui_case inactive
  local out="$CASE/out.json"
  # Absence needs a window: the activated control admits its nudge well inside it.
  v2_tui "$CASE" "$(spec '{"inactive":true,"steps":[{"do":"sleep","ms":1500},{"do":"registration"}]}')" "$out"
  jq -e '.prompts == [] and .metadataWrites == 0 and .environmentPushes == []' "$out" >/dev/null \
    || fail "a TUI without activation published or prompted: $(cat "$out")"
  jq -e '.steps[1] | has("error")' "$out" >/dev/null || fail "a TUI without activation registered a claim"
  pass "tui: a TUI without activation never publishes, pushes, or prompts (contrast: activation case)"
}

test_copied_activation_is_inert_in_another_process() {
  v2_require_native copied-activation || return $?
  tui_case copied-activation
  sleep 120 >/dev/null 2>&1 &
  local foreign=$! out="$CASE/out.json"
  v2_track "$foreign"
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson p "$foreign" '{foreignOwnerPid: $p, steps: [{do: "sleep", ms: 1500}, {do: "registration"}]}')")" "$out"
  jq -e '.setup | startswith("threw")' "$out" >/dev/null || fail "an activation for another process was accepted: $(jq -c .setup "$out")"
  jq -e '.prompts == [] and .metadataWrites == 0 and .environmentPushes == []' "$out" >/dev/null \
    || fail "a copied activation published or prompted: $(cat "$out")"
  jq -e '.steps[1] | has("error")' "$out" >/dev/null || fail "a copied activation registered a claim"
  pass "tui: an activation copied into another process is refused before any publication"
}

# A root session in a subdirectory of the lead's checkout is not that root:
# its activation is refused, and its events never drive the real owner.
test_subdirectory_root_never_owns_or_drives_the_lead() {
  v2_require_native subdirectory || return $?
  tui_case subdirectory 1
  v2_session "$CASE" ses_sub "$V2_CODE_ROOT/.opencode"
  local out="$CASE/out-sub.json" lead="$CASE/out-lead.json" steps
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"sleep","ms":1000},{"do":"registration"}]}' ses_sub)" "$out" sub-spec.json
  jq -e '.setup | test("not this exact root")' "$out" >/dev/null || fail "a subdirectory root was activated as the lead: $(jq -c .setup "$out")"
  jq -e '.prompts == [] and .metadataWrites == 0' "$out" >/dev/null || fail "the refused subdirectory activation published or prompted"
  # The real owner ignores the subdirectory session's events: no reconcile, no prompt.
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" \
    '$a + [{do: "event", event: {type: "session.execution.started", data: {sessionID: "ses_sub"}}},
           {do: "event", event: {type: "session.execution.succeeded", data: {sessionID: "ses_sub"}}}, {do: "sleep", ms: 1500}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$lead" lead-spec.json
  step_ok "$lead" 3 "positive control: the real lead did not arm"
  [ "$(jq '[.admitted[] | select(.text | test("fm-session-start") | not)] | length' "$lead")" = 0 ] \
    || fail "a subdirectory session's events produced a lead prompt: $(jq -c '.admitted' "$lead")"
  pass "tui: a subdirectory root is refused as owner and its events never drive the real lead"
}

test_same_tui_reload_does_not_renudge() {
  v2_require_native reload || return $?
  tui_case reload
  local out="$CASE/out.json"
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"wait","until":"admitted","match":"fm-session-start"},{"do":"cleanup"},{"do":"setup-again"},{"do":"sleep","ms":2500}]}')" "$out"
  [ "$(startup_admissions "$out")" = 1 ] || fail "a same-TUI reload admitted another startup nudge: $(jq -c '.admitted' "$out")"
  jq -e '.steps[1].ok and .steps[2].ok' "$out" >/dev/null || fail "reload cycle failed: $(jq -c '.steps' "$out")"
  pass "tui: a same-TUI reload reuses the claim and admits no second startup nudge"
}
test_startup_nudge_timeout_is_not_silently_dropped() {
  v2_require_native nudge-timeout || return $?
  tui_case nudge-timeout
  local root="$CASE/root" out="$CASE/out.json"
  mkdir -p "$root"
  cp -R "$V2_CODE_ROOT/bin" "$root/bin"
  cp "$V2_CODE_ROOT/AGENTS.md" "$root/AGENTS.md"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$root/bin/fm-sessionstart-nudge.sh"
  root=$(cd -P "$root" && pwd -P)
  v2_session "$CASE" ses_lead "$root"
  v2_tui "$CASE" "$(spec "$(jq -nc --arg r "$root" '{root: $r, steps: [{do: "sleep", ms: 1000}]}')")" "$out"
  jq -e '.setup == "ok"' "$out" >/dev/null || fail "fixture: activation did not complete: $(jq -c '{setup, failures}' "$out")"
  jq -e '(.admitted | length) > 0 or ([.failures[] | select(test("nudge|startup|timed out|signal"; "i"))] | length) > 0' "$out" >/dev/null \
    || fail "a startup nudge helper that timed out was silently dropped (no admission, no recorded failure): $(jq -c '{admitted, failures}' "$out")"
  pass "tui: a timed-out startup nudge helper is never silently dropped"
}

# B2: the routing push must not strip the lead shell's PATH and HOME.
test_routing_push_preserves_shell_environment() {
  v2_require_native env-preserved || return $?
  tui_case env-preserved
  local out="$CASE/out.json"
  # shellcheck disable=SC2016 # expanded by the lead model shell, not here
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"wait","until":"admitted","match":"fm-session-start"},{"do":"shell","command":"printf \"%s|%s|%s\" \"${HOME:-}\" \"${PATH:-}\" \"${FM_HOME:-}\""}]}')" "$out"
  jq -e '.steps[1].stdout | split("|") | (.[0] | length > 0) and (.[1] | length > 0) and (.[2] | length > 0)' "$out" >/dev/null \
    || fail "after the routing push the lead model shell lost HOME/PATH or FM_HOME: $(jq -c '.steps[1]' "$out")"
  pass "tui: the routing push keeps the lead model shell's HOME and PATH alongside the frozen paths"
}

# M1: a plain observer's environment push must not leave the lead's shells
# without authority beyond one reconcile.
test_observer_environment_push_recovers() {
  v2_require_native observer-push || return $?
  tui_case observer-push
  local out="$CASE/out.json" steps
  # The observer's environment keeps only this run's registry namespace (so the
  # production helper never reads the operator's default namespace) and lacks
  # every frozen FM_* routing value.
  steps=$(jq -nc --argjson l "$(lock_step)" --argjson h "$(helper_step)" --arg p "$PATH" --arg hm "$HOME" --arg ns "$FM_V2_REGISTRY_NAMESPACE" \
    '[{do: "wait", until: "admitted", match: "fm-session-start"}, $l, {do: "wait", until: "lock"}, $h,
      {do: "observer-push", variables: {PATH: $p, HOME: $hm, FM_V2_REGISTRY_NAMESPACE: $ns}}, $h,
      ($h + {do: "wait", until: "shell-ok", timeoutMs: 6000})]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  jq -e '.steps[1].code == 0 and .steps[3].code == 0' "$out" >/dev/null || fail "positive control: lead could not lock and prove: $(jq -c '.steps[1,3]' "$out")"
  jq -e '.steps[5].code != 0' "$out" >/dev/null || fail "fixture vacuous: the observer push did not displace the lead's routing: $(jq -c '.steps[5]' "$out")"
  step_ok "$out" 6 "after an observer's environment push the lead shell did not recover helper authority within one reconcile"
  pass "tui: an observer's environment push displaces routing and the owner restores it within one reconcile"
}

# M3 with explicit rebind: after a service restart the stale proof refuses the
# lead's shells; the same owner's /firstmate-rebind republishes the new
# service incarnation and helper, guard scope and watcher recover under it.
test_explicit_rebind_after_service_restart() {
  v2_require_native service-restart || return $?
  tui_case service-restart 1
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --argjson h "$(helper_step)" --argjson e "$(lead_env_with_path)" \
    '$a + [$h, {do: "restart-service"}, ($h + {extraEnv: $e}), {do: "command", name: "firstmate-rebind"},
      ($h + {extraEnv: $e, do: "wait", until: "shell-ok", timeoutMs: 10000}), {do: "wait", until: "watcher"}, {do: "registration"}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  step_ok "$out" 3 "positive control: the lead did not arm before the restart"
  jq -e '.steps[4].code == 0' "$out" >/dev/null || fail "positive control: helper proof failed before the restart: $(jq -c '.steps[4]' "$out")"
  jq -e '.steps[5] | has("error") | not' "$out" >/dev/null || fail "fixture: the replacement service did not start: $(jq -c '.steps[5]' "$out")"
  jq -e '.steps[6].code != 0' "$out" >/dev/null || fail "a stale service proof was accepted before explicit rebind: $(jq -c '.steps[6]' "$out")"
  jq -e '.steps[7].ok' "$out" >/dev/null || fail "the owner's /firstmate-rebind command did not complete: $(jq -c '{c: .steps[7], failures}' "$out")"
  step_ok "$out" 8 "after explicit rebind the lead shells stay refused"
  step_ok "$out" 9 "after explicit rebind no watcher serves the lead"
  jq -e '.steps[5].newPid as $n | .steps[10].record.servicePID == $n and .steps[10].record.lifecycle == "active"' "$out" >/dev/null \
    || fail "the registration does not name the new service incarnation as active: $(jq -c '.steps[10]' "$out")"
  pass "tui: stale proof refuses after a service restart until the owner's /firstmate-rebind republishes; helper and watcher recover"
}

# --- reconcile triggers: event vs timer fallback, stream loss -----------------

# Event-triggered first arm (M7 turn end): with the periodic reconcile on a
# manual clock, a supervision need that appears after setup is NOT armed until
# the lead's turn-end event arrives; the event then arms exactly one watcher
# and produces no prompt.
test_turn_end_event_arms_one_watcher_without_prompt() {
  v2_require_native turn-end-event || return $?
  tui_case turn-end-event 0
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson l "$(lock_step)" --arg meta "$HOME_DIR/state/t1.meta" --argjson w "$(watchers_step)" \
    '[{do: "wait", until: "admitted", match: "fm-session-start"}, $l, {do: "wait", until: "lock"},
      {do: "write", path: $meta, text: "kind=ship\n"}, {do: "sleep", ms: 2500}, {do: "wait", until: "no-watcher", timeoutMs: 500},
      {do: "event", event: {type: "session.execution.succeeded", data: {sessionID: "ses_lead"}}},
      {do: "wait", until: "watcher", timeoutMs: 10000}, {do: "sleep", ms: 1000}, $w]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{manualTimer: true, steps: $s}')")" "$out"
  step_ok "$out" 5 "fixture: a watcher armed without any event or timer tick"
  step_ok "$out" 7 "the lead's turn-end event did not arm a watcher (event-triggered reconcile missing)"
  jq -e '.steps[9].stdout | test("watchers=1")' "$out" >/dev/null || fail "turn end did not leave exactly one watcher: $(jq -c '.steps[9]' "$out")"
  [ "$(jq '[.admitted[] | select(.text | test("fm-session-start") | not)] | length' "$out")" = 0 ] \
    || fail "turn end produced a prompt: $(jq -c '.admitted' "$out")"
  pass "tui: a turn-end event (not the timer) arms exactly one watcher and produces no prompt"
}

# Stream loss: after the native event stream fails, events no longer reach the
# owner; the periodic fallback alone arms the watcher, and a genuine durable
# wake is then admitted exactly once, with no session.created replay and no
# human turn.
test_stream_loss_falls_back_to_timer_and_recovers_a_wake() {
  v2_require_native stream-loss || return $?
  tui_case stream-loss 0
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson l "$(lock_step)" --arg meta "$HOME_DIR/state/t1.meta" --arg st "$HOME_DIR/state/alpha.status" --arg w "$WAKE" \
    '[{do: "wait", until: "admitted", match: "fm-session-start"}, $l, {do: "wait", until: "lock"},
      {do: "stream-error"}, {do: "write", path: $meta, text: "kind=ship\n"},
      {do: "event", event: {type: "session.execution.succeeded", data: {sessionID: "ses_lead"}}},
      {do: "sleep", ms: 2500}, {do: "wait", until: "no-watcher", timeoutMs: 500},
      {do: "tick"}, {do: "wait", until: "watcher", timeoutMs: 10000},
      {do: "write", path: $st, text: "done: alpha finished\n"}, {do: "wait", until: "admitted", match: $w, timeoutMs: 20000}, {do: "sleep", ms: 1500}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{manualTimer: true, steps: $s}')")" "$out"
  step_ok "$out" 7 "an event reached the owner after the stream was lost"
  jq -e '.steps[8].timers >= 1' "$out" >/dev/null || fail "fixture: no periodic reconcile timer was registered"
  step_ok "$out" 9 "the timer fallback did not arm a watcher after stream loss"
  step_ok "$out" 11 "a genuine durable wake was not admitted after stream loss"
  [ "$(wake_admissions "$out")" = 1 ] || fail "expected exactly one wake admission after stream loss: $(jq -c '.admitted' "$out")"
  [ "$(jq '.admitted | length' "$out")" = 2 ] || fail "stream loss produced prompts beyond the startup nudge and the one wake: $(jq -c '.admitted' "$out")"
  jq -e '[.failures[] | select(test("event stream"))] | length >= 1' "$out" >/dev/null || fail "stream loss was not reported as a bounded diagnostic"
  pass "tui: after stream loss the timer fallback arms and a genuine wake is admitted once, without replayed events"
}

# Interrupted turn: no self-generated continuation. Positive control in the same
# run: a genuine durable fleet wake is admitted exactly once afterwards.
test_interrupt_alone_admits_nothing_but_a_genuine_wake_does() {
  v2_require_native interrupted || return $?
  tui_case interrupted 1
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg st "$HOME_DIR/state/alpha.status" --arg w "$WAKE" \
    '$a + [{do: "event", event: {type: "session.execution.started", data: {sessionID: "ses_lead"}}},
      {do: "event", event: {type: "session.execution.interrupted", data: {sessionID: "ses_lead"}}},
      {do: "sleep", ms: 4000}, {do: "write", path: $st, text: "done: alpha finished\n"},
      {do: "wait", until: "admitted", match: $w, timeoutMs: 20000}, {do: "sleep", ms: 1500}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  step_ok "$out" 3 "positive control: the lead did not arm"
  [ "$(jq --argjson t "$(jq '.steps[5].at' "$out")" --argjson w "$(jq '.steps[7].at' "$out")" '[.admitted[] | select(.at > $t and .at < $w)] | length' "$out")" = 0 ] \
    || fail "an interrupted turn alone produced an admission: $(jq -c '.admitted' "$out")"
  [ "$(wake_admissions "$out")" = 1 ] \
    || fail "positive control: a genuine durable wake after the interruption was not admitted exactly once: $(jq -c '{admitted, failures}' "$out")"
  pass "tui: an interrupted turn alone admits nothing, a later genuine durable wake is admitted once"
}

# --- wake delivery: identity, ordering, durability, successor ------------------

# Every attempt of one logical wake carries the same immutable id and text and
# explicit queue delivery; the first attempt happens only after the handling
# handoff was confirmed (recovery marker in handling) with a live successor.
assert_wake_delivery() {  # <out> <label>
  local prompts
  prompts=$(wake_prompts "$1")
  printf '%s' "$prompts" | jq -e 'length >= 1' >/dev/null || fail "$2: fixture vacuous, no wake was ever attempted"
  printf '%s' "$prompts" | jq -e '(map(.id) | unique | length) == 1 and (.[0].id | startswith("msg_"))' >/dev/null \
    || fail "$2: attempts of one wake used different or invalid message ids: $(printf '%s' "$prompts" | jq -c 'map(.id)')"
  printf '%s' "$prompts" | jq -e '(map(.text) | unique | length) == 1' >/dev/null || fail "$2: wake text changed between attempts"
  printf '%s' "$prompts" | jq -e 'all(.delivery == "queue")' >/dev/null || fail "$2: a wake attempt was not explicitly queued"
  printf '%s' "$prompts" | jq -e '.[0].marker | test(":handling:")' >/dev/null \
    || fail "$2: the first wake admission preceded the handling handoff (marker $(printf '%s' "$prompts" | jq -c '.[0].marker'))"
  printf '%s' "$prompts" | jq -e '.[0].watcherLive == true' >/dev/null || fail "$2: no live successor watcher at the first wake admission"
}

rows_and_watchers_steps() {  # trailing steps: durable rows count, singleton watcher count
  jq -nc --arg q "$HOME_DIR/state/.wake-queue" --argjson w "$(watchers_step)" '[{do: "shell", command: ("grep -c alpha " + $q)}, $w]'
}

assert_rows_and_singleton() {  # <out> <label>
  jq -e '(.steps[-2].stdout | gsub("\\s"; "") | tonumber) >= 1' "$1" >/dev/null || fail "$2: admission consumed the canonical wake row: $(jq -c '.steps[-2]' "$1")"
  jq -e '.steps[-1].stdout | test("watchers=1")' "$1" >/dev/null || fail "$2: not exactly one live watcher at the end: $(jq -c '.steps[-1]' "$1")"
}

# A wake whose admission is refused for longer than the journal's initial
# budget is not stranded while the owner lives; with a same-owner reload in the
# middle the pending admission is reconciled, not re-minted.
outage_case() {  # <case> <reload:0|1>
  tui_case "$1" 1
  local out="$CASE/out.json" steps reload='[]'
  [ "$2" = 0 ] || reload='[{"do":"cleanup"},{"do":"setup-again"}]'
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg st "$HOME_DIR/state/alpha.status" --arg w "$WAKE" \
    --argjson r "$reload" --argjson t "$(rows_and_watchers_steps)" \
    '$a + [{do: "outage", ms: 9000}, {do: "write", path: $st, text: "done: alpha finished\n"},
      {do: "wait", until: "prompted", match: $w, timeoutMs: 20000}] + $r +
      [{do: "wait", until: "admitted", match: $w, timeoutMs: 40000}, {do: "sleep", ms: 1500}] + $t')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" --arg w "$WAKE" '{faultMatch: $w, steps: $s}')")" "$out"
  OUT=$out
  jq -e --arg w "$WAKE" '[.prompts[] | select(.text | test($w))] | length >= 2' "$out" >/dev/null \
    || fail "fixture vacuous: the wake was never refused during the outage: $(jq -c '{prompts: [.prompts[] | {id, at}], failures}' "$out")"
  [ "$(wake_admissions "$out")" = 1 ] || fail "after an admission outage the lead must receive exactly one wake: $(jq -c '{admitted: [.admitted[] | {id, at}], failures}' "$out")"
  assert_wake_delivery "$out" "$1"
  assert_rows_and_singleton "$out" "$1"
}

test_admission_outage_never_strands_the_wake() {
  v2_require_native outage || return $?
  outage_case outage 0
  pass "tui: an outage-refused wake is admitted once under one id and text, queued, after the handoff, with rows durable and one watcher"
}

test_reload_during_outage_keeps_the_pending_id() {
  v2_require_native outage-reload || return $?
  outage_case outage-reload 1
  pass "tui: a same-owner reload during an outage reconciles the pending wake under its original id and text"
}

fault_case() {  # <case> <fault-json>
  tui_case "$1" 1
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg st "$HOME_DIR/state/alpha.status" --arg w "$WAKE" --argjson t "$(rows_and_watchers_steps)" \
    '$a + [{do: "write", path: $st, text: "done: alpha finished\n"}, {do: "wait", until: "admitted", match: $w, timeoutMs: 30000}, {do: "sleep", ms: 2000}] + $t')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" --arg w "$WAKE" --argjson f "$2" '{faultMatch: $w, steps: $s} + $f')")" "$out"
  OUT=$out
  [ "$(wake_admissions "$out")" = 1 ] || fail "$1: expected exactly one wake admission: $(jq -c '{admitted, failures}' "$out")"
  jq -e --arg w "$WAKE" '[.prompts[] | select(.text | test($w))] | length >= 2' "$out" >/dev/null || fail "$1: fixture vacuous, no retry happened"
  assert_wake_delivery "$out" "$1"
  assert_rows_and_singleton "$out" "$1"
}

test_lost_receipt_admits_once_without_failure() {
  v2_require_native lost-receipt || return $?
  fault_case lost-receipt '{"lostAckPrompts": 1}'
  jq -e '[.failures[] | select(test("remains pending"))] | length == 0' "$OUT" >/dev/null \
    || fail "a lost receipt after admission was reported as pending: $(jq -c .failures "$OUT")"
  pass "tui: a lost admission receipt resolves to one admission under one id and text, with no pending diagnostic"
}

test_rejected_admissions_retry_one_id() {
  v2_require_native rejected-admission || return $?
  fault_case rejected-admission '{"rejectPrompts": 2}'
  pass "tui: rejected wake admissions retry under one id and text through the real coordinator and admit once"
}

# Owner exit with an unadmitted wake: cleanup awaits the watcher's retirement,
# leaves the episode recoverable and the row durable, retires the registration;
# an explicit relaunch of the same session then re-presents that wake exactly
# once under its original id and text.
test_owner_exit_then_next_owner_represents_the_wake() {
  v2_require_native owner-exit || return $?
  tui_case owner-exit 1
  local first="$CASE/out-first.json" second="$CASE/out-second.json" steps state="$HOME_DIR/state"
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg st "$state/alpha.status" --arg w "$WAKE" --arg s "$state" \
    '$a + [{do: "outage", ms: 600000}, {do: "write", path: $st, text: "done: alpha finished\n"},
      {do: "wait", until: "prompted", match: $w, timeoutMs: 20000}, {do: "cleanup"},
      {do: "shell", command: ("p=$(cat " + $s + "/.watch.lock/pid 2>/dev/null); if [ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null; then echo watcher-live; else echo watcher-gone; fi; cat " + $s + "/.watcher-down; grep -c alpha " + $s + "/.wake-queue")},
      {do: "registration"}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" --arg w "$WAKE" '{faultMatch: $w, steps: $s, cleanupAtEnd: false}')")" "$first" first-spec.json
  jq -e '.steps[7].ok' "$first" >/dev/null || fail "owner cleanup failed: $(jq -c '.steps[7]' "$first")"
  jq -e '.steps[8].stdout | test("watcher-gone")' "$first" >/dev/null || fail "owner cleanup resolved while its watcher was still live: $(jq -c '.steps[8]' "$first")"
  jq -e '.steps[8].stdout | test(":downtime:")' "$first" >/dev/null || fail "owner exit did not leave the unadmitted episode recoverable: $(jq -c '.steps[8]' "$first")"
  jq -e '.steps[8].stdout | test("\\n[1-9]")' "$first" >/dev/null || fail "owner exit consumed the durable wake row: $(jq -c '.steps[8]' "$first")"
  jq -e '.steps[9].record.lifecycle == "retired"' "$first" >/dev/null || fail "owner exit did not retire the registration: $(jq -c '.steps[9]' "$first")"
  [ "$(wake_admissions "$first")" = 0 ] || fail "fixture: the first owner admitted the wake during the outage"
  steps=$(jq -nc --argjson l "$(lock_step)" --arg w "$WAKE" \
    '[{do: "wait", until: "admitted", match: "fm-session-start"}, $l, {do: "wait", until: "lock"},
      {do: "wait", until: "admitted", match: $w, timeoutMs: 40000}, {do: "sleep", ms: 2000}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$second" second-spec.json
  [ "$(wake_admissions "$second")" = 1 ] || fail "the next owner did not re-present the pending wake exactly once: $(jq -c '{admitted, failures}' "$second")"
  jq -e --slurpfile f "$first" --arg w "$WAKE" '
      ([.admitted[] | select(.text | test($w))][0]) as $a
      | ([$f[0].prompts[] | select(.text | test($w))][0]) as $p
      | $a.id == $p.id and $a.text == $p.text' "$second" >/dev/null \
    || fail "the next owner re-presented the wake under a different id or text"
  pass "tui: owner exit retires supervision and keeps the wake durable; the next explicit owner re-presents it once under its original id and text"
}

# Two homes on one service: a durable wake in home B reaches only lead B, and
# lead A ignores B's session events.
test_two_homes_route_wakes_to_their_own_lead() {
  v2_require_native two-homes || return $?
  tui_case two-homes 1 ses_a
  local home_a=$HOME_DIR out_a="$CASE/out-a.json" out_b="$CASE/out-b.json" steps_a steps_b pid_a
  KEEP_SERVICE=1 tui_case two-homes 1 ses_b
  local home_b=$HOME_DIR
  HOME_DIR=$home_a
  steps_a=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg flag "$CASE/a-armed" --arg flagb "$CASE/b-done" \
    '$a + [{do: "write", path: $flag, text: "armed\n"},
      {do: "event", event: {type: "session.execution.succeeded", data: {sessionID: "ses_b"}}},
      {do: "wait", until: "file", path: $flagb, timeoutMs: 60000}, {do: "sleep", ms: 2000}]')
  v2_tui_bg "$CASE" "$(spec "$(jq -nc --argjson s "$steps_a" '{steps: $s}')" ses_a)" "$out_a" a-spec.json
  pid_a=$V2_TUI_PID
  HOME_DIR=$home_b
  steps_b=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg flag "$CASE/a-armed" --arg st "$home_b/state/beta.status" --arg w "$WAKE" --arg finished "$CASE/b-done" \
    '$a + [{do: "wait", until: "file", path: $flag, timeoutMs: 60000}, {do: "write", path: $st, text: "done: beta finished\n"},
      {do: "wait", until: "admitted", match: $w, timeoutMs: 30000}, {do: "write", path: $finished, text: "done\n"}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps_b" '{steps: $s}')" ses_b)" "$out_b" b-spec.json
  wait "$pid_a"
  step_ok "$out_a" 3 "positive control: lead A did not arm"
  step_ok "$out_b" 3 "positive control: lead B did not arm"
  [ "$(wake_admissions "$out_b")" = 1 ] || fail "home B's wake did not reach lead B exactly once: $(jq -c '{admitted, failures}' "$out_b")"
  jq -e '[.admitted[] | select(.sessionID != "ses_b")] | length == 0' "$out_b" >/dev/null || fail "lead B admitted input for another session"
  [ "$(wake_admissions "$out_a")" = 0 ] || fail "home B's wake reached lead A: $(jq -c '.admitted' "$out_a")"
  jq -e '[.admitted[] | select(.sessionID != "ses_a")] | length == 0' "$out_a" >/dev/null || fail "lead A admitted input for another session"
  pass "tui: on one service a durable wake in home B reaches only lead B, and lead A ignores B's events"
}

# M5 genuine: a pending wake admission whose captured canonical rows the lead
# drains and acknowledges through the real drain/ack owner is retired as
# acknowledged, never admitted, with no repeated failure. Negative control: a
# missing queue does not establish acknowledgement.
test_pending_admission_retires_after_real_drain_and_ack() {
  v2_require_native acked-pending || return $?
  tui_case acked-pending 1
  local out="$CASE/out.json" steps state="$HOME_DIR/state"
  local phase='cat '"$state"'/.opencode-v2-admissions/*/msg_*.json 2>/dev/null | jq -r "select(.kind == \"wake\") | .phase"'
  # shellcheck disable=SC2016 # expanded by the lead model shell
  local drain_ack='err=$(bin/fm-wake-drain.sh 2>&1 >/dev/null); seq=$(printf "%s\n" "$err" | sed -n "s/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p"); gen=$(printf "%s\n" "$err" | sed -n "s/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p"); [ -n "$seq" ] && [ -n "$gen" ] && bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" && echo acked'
  steps=$(jq -nc --argjson a "$(owned_and_armed "$(lock_step)")" --arg st "$state/alpha.status" --arg w "$WAKE" --arg q "$state/.wake-queue" \
    --arg phase "$phase" --arg da "$drain_ack" --argjson e "$(lead_env_with_path)" \
    '$a + [{do: "outage", ms: 600000}, {do: "write", path: $st, text: "done: alpha finished\n"},
      {do: "wait", until: "prompted", match: $w, timeoutMs: 20000},
      {do: "shell", command: ("mv " + $q + " " + $q + ".away")}, {do: "sleep", ms: 5000}, {do: "shell", command: $phase},
      {do: "shell", command: ("mv " + $q + ".away " + $q)},
      {do: "shell", command: $da, extraEnv: $e},
      {do: "wait", until: "shell-ok", command: ($phase + " | grep -qx acknowledged"), timeoutMs: 15000},
      {do: "sleep", ms: 6000}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" --arg w "$WAKE" '{faultMatch: $w, steps: $s}')")" "$out"
  step_ok "$out" 6 "fixture: no wake admission was attempted"
  jq -e '.steps[9].stdout | test("acknowledged") | not' "$out" >/dev/null \
    || fail "negative control: a missing canonical queue established acknowledgement: $(jq -c '.steps[9]' "$out")"
  jq -e '.steps[11].stdout | test("acked")' "$out" >/dev/null || fail "the real drain/ack owner did not acknowledge the rows: $(jq -c '.steps[11]' "$out")"
  step_ok "$out" 12 "the pending admission was not retired as acknowledged after the real drain/ack"
  [ "$(wake_admissions "$out")" = 0 ] || fail "an acknowledged obligation was admitted anyway: $(jq -c '.admitted' "$out")"
  local acked_at attempts_after
  acked_at=$(jq '.steps[12].at' "$out")
  attempts_after=$(jq --argjson t "$acked_at" --arg w "$WAKE" '[.prompts[] | select(.at > $t and (.text | test($w)))] | length' "$out")
  [ "$attempts_after" = 0 ] || fail "admission attempts continued after acknowledgement: $attempts_after"
  jq -e '[.failures[] | select(test("remains pending"))] | length <= 1' "$out" >/dev/null || fail "the pending diagnostic repeated: $(jq -c .failures "$out")"
  pass "tui: after the real drain/ack the pending wake obligation is retired as acknowledged with no admission or repeated failure; a missing queue does not count"
}
# Worker busy state is bound to the worker's recorded session. The real
# fm-spawn writes the V2 worker plugin into an isolated task worktree; after the
# worker latches busy, a child session's start and terminal events must neither
# clear the worker's state nor touch its notification marker, and the worker's
# own terminal event then settles it. Positive control: the worker's events do
# change state.
test_worker_child_event_isolation() {
  local case_dir="$TMP_ROOT/worker-child" home proj wt fakebin id=v2-child-iso out state plugin
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" opencode)
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "wt-worker-child"
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off) \
    || fail "the real spawn fixture failed: $out"
  state="$home/state"
  plugin="$wt/.opencode/plugins/fm-busy-state.js"
  [ -f "$plugin" ] || fail "fm-spawn wrote no worker busy plugin"
  printf '%s\n' '{"version":1,"sessionID":"ses_worker"}' > "$state/$id.opencode-v2-session.json"
  drive() {  # <events-json>
    PLUGIN="$plugin" "$V2_NODE_BIN" --input-type=module - "$(jq -nc --arg d "$wt" --argjson e "$1" '{directory: $d, events: $e,
      sessions: {ses_worker: {id: "ses_worker", location: {directory: $d}}, ses_child: {id: "ses_child", parentID: "ses_worker", location: {directory: $d}}}}')" <<'EOF2'
import { pathToFileURL } from "node:url";
const spec = JSON.parse(process.argv[2]);
const { setupBusyStateV2 } = await import(pathToFileURL(process.env.PLUGIN).href);
const queue = []; let notify = null; const abort = new AbortController();
const ctx = { location: { directory: spec.directory },
  event: { subscribe() { return { async *[Symbol.asyncIterator]() { while (!abort.signal.aborted) { if (queue.length) { yield queue.shift(); continue; } await new Promise((r) => { notify = r; }); } } }; } },
  session: { async get({ sessionID }) { const i = spec.sessions[sessionID]; if (!i) throw new Error("missing"); return i; } } };
const cleanup = await setupBusyStateV2(ctx);
await new Promise((r) => setTimeout(r, 30));
for (const event of spec.events) { queue.push(event); notify?.(); await new Promise((r) => setTimeout(r, 60)); }
await new Promise((r) => setTimeout(r, 400));
cleanup?.(); abort.abort(); notify?.();
EOF2
  }
  classify() { bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux fake:w opencode "$2" "$3"' _ "$ROOT" "$id" "$state"; }
  rm -f "$state/$id.turn-ended"
  # One plugin instance: the worker latches busy, then its child runs a turn.
  drive '[{"type":"session.execution.started","data":{"sessionID":"ses_worker"}},{"type":"session.created","data":{"sessionID":"ses_child"}},{"type":"session.execution.started","data":{"sessionID":"ses_child"}},{"type":"session.execution.succeeded","data":{"sessionID":"ses_child"}}]' >/dev/null
  [ "$(classify)" = "busy opencode-plugin" ] || fail "a child session's events changed the worker's busy state: $(classify)"
  [ ! -e "$state/$id.turn-ended" ] || fail "a child session's terminal event touched the worker notification marker"
  drive '[{"type":"session.execution.started","data":{"sessionID":"ses_worker"}},{"type":"session.execution.succeeded","data":{"sessionID":"ses_worker"}}]' >/dev/null
  [ "$(classify)" = "idle opencode-plugin" ] || fail "positive control: the worker's own terminal event did not settle it: $(classify)"
  [ -e "$state/$id.turn-ended" ] || fail "positive control: the worker's terminal event did not notify"
  pass "worker: after the worker latches busy, its child session's events neither clear it nor notify; its own terminal event does"
}

v2_run_cases \
  test_activation_publishes_and_nudges_once_without_events \
  test_inactive_tui_stays_inert \
  test_copied_activation_is_inert_in_another_process \
  test_subdirectory_root_never_owns_or_drives_the_lead \
  test_same_tui_reload_does_not_renudge \
  test_startup_nudge_timeout_is_not_silently_dropped \
  test_routing_push_preserves_shell_environment \
  test_observer_environment_push_recovers \
  test_explicit_rebind_after_service_restart \
  test_turn_end_event_arms_one_watcher_without_prompt \
  test_stream_loss_falls_back_to_timer_and_recovers_a_wake \
  test_interrupt_alone_admits_nothing_but_a_genuine_wake_does \
  test_admission_outage_never_strands_the_wake \
  test_reload_during_outage_keeps_the_pending_id \
  test_lost_receipt_admits_once_without_failure \
  test_rejected_admissions_retry_one_id \
  test_owner_exit_then_next_owner_represents_the_wake \
  test_two_homes_route_wakes_to_their_own_lead \
  test_pending_admission_retires_after_real_drain_and_ack \
  test_worker_child_event_isolation
