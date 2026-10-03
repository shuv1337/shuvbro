#!/usr/bin/env bash
# TUI owner acceptance for OpenCode V2 on the shared service (issue #1 rows
# "New lead session", "Attach/resume", "Two clients", "Busy lead receives
# actionable wake", "Watcher and turn-end race", "Detach, TUI exit, server
# death"; Fable findings B1, B2, M1, M3, M5, M7).
#
# The production TUI entry runs under a genuine activation for the driver's own
# process (tests/assets/fm-opencode-v2-native-harness.mjs `tui`), against a
# service stand-in that parents model shells and hosts the production server
# entry's bindingStatus. Every "never" case is paired with a positive control
# from the same driver: an inactive or refused setup must be contrasted with an
# activated one that publishes, nudges and arms.
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

# One case directory with a service, an external home and the lead session.
tui_case() {  # <case> [supervision-needed:0|1]
  CASE="$TMP_ROOT/$1"
  v2_namespace "$1"
  HOME_DIR=$(v2_make_home "$CASE/home")
  mkdir -p "$HOME_DIR/data"
  # Supervision need comes from the canonical owner (fm-supervision-lib): one
  # in-flight task record. It names no endpoint, so the watcher raises no
  # stale or missing-endpoint wakes for it.
  [ "${2:-0}" = 0 ] || printf 'kind=ship\n' > "$HOME_DIR/state/t1.meta"
  v2_start_service "$CASE"
  v2_session "$CASE" ses_lead "$V2_CODE_ROOT"
}

spec() {  # <extra-json>
  jq -nc --arg r "$V2_CODE_ROOT" --arg h "$HOME_DIR" --arg pf "$V2_STATE_DIR/pids" --argjson x "${1:-{\}}" \
    '{sessionID: "ses_lead", root: $r, home: $h, state: ($h + "/state"), config: ($h + "/config"), pidsFile: $pf} + $x'
}

lead_env_with_path() {
  jq -nc --argjson e "$(v2_lead_env "$HOME_DIR")" --arg p "$PATH" '$e + {PATH: $p}'
}

startup_admissions() {  # <out>
  jq '[.admitted[] | select(.sessionID == "ses_lead" and (.text | test("fm-session-start")))] | length' "$1"
}

# Positive control for everything below: activation publishes the claim and
# marker, proves the service, pushes routing, and admits one startup nudge,
# with no session.created or idle event ever delivered (quiet exact-id attach).
test_activation_publishes_and_nudges_once_without_events() {
  v2_require_native activation || return $?
  tui_case activation
  local out="$CASE/out.json"
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"sleep","ms":500},{"do":"registration"}]}')" "$out" || fail "tui driver failed: $(cat "$CASE/tui.log")"
  jq -e '.setup == "ok"' "$out" >/dev/null || fail "activated setup did not complete: $(jq -c '{setup, failures}' "$out")"
  [ "$(startup_admissions "$out")" = 1 ] || fail "expected exactly one startup nudge admission: $(jq -c '.admitted' "$out")"
  jq -e '.admitted[0].id | startswith("msg_")' "$out" >/dev/null || fail "startup admission carried no stable message id"
  jq -e --arg c "$(jq -r .claimID "$out")" '.steps[1].record.claimID == $c' "$out" >/dev/null \
    || fail "the activation's exact claim was not registered: $(jq -c '.steps[1]' "$out")"
  jq -e --arg c "$(jq -r .claimID "$out")" '.firstmateV2Lead.claimID == $c and .firstmateV2Lead.sessionID == "ses_lead"' \
    <(jq '.ses_lead.metadata' "$CASE/sessions.json") >/dev/null || fail "the exact lead marker was not written: $(cat "$CASE/sessions.json")"
  pass "tui: activation registers the exact claim and marker and admits one startup nudge with no session events"
}

test_inactive_tui_stays_inert() {
  v2_require_native inactive || return $?
  tui_case inactive
  local out="$CASE/out.json"
  v2_tui "$CASE" "$(spec '{"inactive":true,"steps":[{"do":"sleep","ms":500},{"do":"registration"}]}')" "$out"
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
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson p "$foreign" '{foreignOwnerPid: $p, steps: [{do: "sleep", ms: 500}, {do: "registration"}]}')")" "$out"
  jq -e '.setup | startswith("threw")' "$out" >/dev/null || fail "an activation for another process was accepted: $(jq -c .setup "$out")"
  jq -e '.prompts == [] and .metadataWrites == 0 and .environmentPushes == []' "$out" >/dev/null \
    || fail "a copied activation published or prompted: $(cat "$out")"
  jq -e '.steps[1] | has("error")' "$out" >/dev/null || fail "a copied activation registered a claim"
  pass "tui: an activation copied into another process is refused before any publication"
}

test_same_tui_reload_does_not_renudge() {
  v2_require_native reload || return $?
  tui_case reload
  local out="$CASE/out.json"
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"sleep","ms":400},{"do":"cleanup"},{"do":"setup-again"},{"do":"sleep","ms":2500}]}')" "$out"
  [ "$(startup_admissions "$out")" = 1 ] || fail "a same-TUI reload admitted another startup nudge: $(jq -c '.admitted' "$out")"
  jq -e '.steps[1].ok and .steps[2].ok' "$out" >/dev/null || fail "reload cycle failed: $(jq -c '.steps' "$out")"
  pass "tui: a same-TUI reload reuses the claim and admits no second startup nudge"
}

# B1 (startup): a startup nudge helper that hangs past its timeout must not be
# silently dropped: either the nudge is admitted or a failure is recorded.
# The lead's code root is a disposable copy of the production bin/ so only the
# nudge helper is replaced.
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
  v2_tui "$CASE" "$(spec '{"steps":[{"do":"sleep","ms":300},{"do":"shell","command":"printf \"%s|%s|%s\" \"${HOME:-}\" \"${PATH:-}\" \"${FM_HOME:-}\""}]}')" "$out"
  jq -e '.steps[1].stdout | split("|") | (.[0] | length > 0) and (.[1] | length > 0) and (.[2] | length > 0)' "$out" >/dev/null \
    || fail "after the routing push the lead model shell lost HOME/PATH or FM_HOME: $(jq -c '.steps[1]' "$out")"
  pass "tui: the routing push keeps the lead model shell's HOME and PATH alongside the frozen paths"
}

lock_step() {  # prints a JSON step that acquires .lock from the lead model shell
  jq -nc --argjson e "$(lead_env_with_path)" '{do: "shell", command: "bash bin/fm-lock.sh", extraEnv: $e}'
}
helper_step() {
  jq -nc --argjson p "{\"PATH\":\"$PATH\"}" '{do: "shell", command: "node bin/fm-opencode-v2-owner.mjs helper \"$FM_STATE_OVERRIDE\"", extraEnv: $p}'
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
    '[{do: "sleep", ms: 300}, $l, {do: "sleep", ms: 2500}, $h, {do: "observer-push", variables: {PATH: $p, HOME: $hm, FM_V2_REGISTRY_NAMESPACE: $ns}}, $h, {do: "sleep", ms: 4500}, $h]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  jq -e '.steps[1].code == 0 and .steps[3].code == 0' "$out" >/dev/null || fail "positive control: lead could not lock and prove: $(jq -c '.steps[1,3]' "$out")"
  jq -e '.steps[7].code == 0' "$out" >/dev/null \
    || fail "after an observer's environment push the lead shell did not recover helper authority within one reconcile: $(jq -c '.steps[5,7]' "$out")"
  pass "tui: an observer's environment push is repaired and the lead shell recovers within one reconcile"
}

# M3: after a service restart the same live owner republishes the new service
# incarnation and its shells recover.
test_same_owner_republishes_after_service_restart() {
  v2_require_native service-restart || return $?
  tui_case service-restart
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson l "$(lock_step)" --argjson h "$(helper_step)" --argjson e "$(lead_env_with_path)" \
    '[{do: "sleep", ms: 300}, $l, {do: "sleep", ms: 2500}, $h, {do: "restart-service"}, {do: "sleep", ms: 2500},
      {do: "command", name: "firstmate-rebind"}, {do: "sleep", ms: 3000}, ($h + {extraEnv: $e}), {do: "registration"}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  jq -e '.steps[1].code == 0 and .steps[3].code == 0' "$out" >/dev/null || fail "positive control: lead could not lock and prove: $(jq -c '.steps[1,3]' "$out")"
  jq -e '.steps[6].ok' "$out" >/dev/null || fail "the owner's /firstmate-rebind command did not complete: $(jq -c '{c: .steps[6], failures}' "$out")"
  jq -e '.steps[8].code == 0' "$out" >/dev/null \
    || fail "after a service restart and same-owner rebind the lead shells stay refused: $(jq -c '.steps[8]' "$out") record=$(jq -c '.steps[9]' "$out")"
  jq -e --argjson n "$(jq '.steps[4].newPid' "$out")" '.steps[9].record.servicePID == $n' "$out" >/dev/null \
    || fail "the registration does not name the new service incarnation: $(jq -c '.steps[9]' "$out")"
  pass "tui: after a service restart the same owner's /firstmate-rebind republishes and its shells recover"
}

wake_admissions() {  # <out>
  jq '[.admitted[] | select(.sessionID == "ses_lead" and (.text | test("WATCHER FIRED")))] | length' "$1"
}

# Interrupted turn: no self-generated continuation. Positive control in the same
# run: a genuine durable fleet wake is admitted exactly once afterwards.
test_interrupt_alone_admits_nothing_but_a_genuine_wake_does() {
  v2_require_native interrupted || return $?
  tui_case interrupted 1
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson l "$(lock_step)" --arg st "$HOME_DIR/state/alpha.status" \
    '[{do: "sleep", ms: 300}, $l, {do: "sleep", ms: 4000},
      {do: "event", event: {type: "session.execution.started", data: {sessionID: "ses_lead"}}},
      {do: "event", event: {type: "session.execution.interrupted", data: {sessionID: "ses_lead"}}},
      {do: "sleep", ms: 4000}, {do: "write", path: $st, text: "done: alpha finished\n"}, {do: "sleep", ms: 12000}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  local interrupted_at
  interrupted_at=$(jq '.steps[4].at' "$out")
  [ "$(jq --argjson t "$interrupted_at" --argjson w "$(jq '.steps[6].at' "$out")" '[.admitted[] | select(.at > $t and .at < $w)] | length' "$out")" = 0 ] \
    || fail "an interrupted turn alone produced an admission: $(jq -c '.admitted' "$out")"
  [ "$(wake_admissions "$out")" = 1 ] \
    || fail "positive control: a genuine durable wake after the interruption was not admitted exactly once: $(jq -c '{admitted, failures}' "$out")"
  pass "tui: an interrupted turn alone admits nothing, a later genuine durable wake is admitted once"
}

# A wake whose admission is refused for longer than the journal's initial
# budget is not stranded while the owner lives: after admission recovers the
# lead receives exactly one wake. With a same-owner reload in the middle, the
# recovered admission keeps the message id the first coordinator used.
outage_case() {  # <case> <reload:0|1>
  tui_case "$1" 1
  local out="$CASE/out.json" steps reload='[]'
  [ "$2" = 0 ] || reload='[{"do":"cleanup"},{"do":"setup-again"}]'
  steps=$(jq -nc --argjson l "$(lock_step)" --arg st "$HOME_DIR/state/alpha.status" --argjson r "$reload" \
    '[{do: "sleep", ms: 300}, $l, {do: "sleep", ms: 4000}, {do: "outage", ms: 9000},
      {do: "write", path: $st, text: "done: alpha finished\n"}, {do: "sleep", ms: 4000}] + $r + [{do: "sleep", ms: 16000}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  jq -e '[.prompts[] | select(.text | test("WATCHER FIRED"))] | length >= 2' "$out" >/dev/null \
    || fail "fixture vacuous: the wake was never refused during the outage: $(jq -c '{prompts: [.prompts[] | {id, at}], failures}' "$out")"
  [ "$(wake_admissions "$out")" = 1 ] \
    || fail "after an admission outage the lead must receive exactly one wake, got $(wake_admissions "$out"): $(jq -c '{admitted: [.admitted[] | {id, at}], failures}' "$out")"
  jq -e '[.prompts[] | select(.text | test("WATCHER FIRED")) | .id] | unique | length == 1' "$out" >/dev/null \
    || fail "the refused and recovered wake admissions used different message ids: $(jq -c '[.prompts[] | {id, at}]' "$out")"
}

test_admission_outage_never_strands_the_wake() {
  v2_require_native outage || return $?
  outage_case outage 0
  pass "tui: an admission outage longer than the initial budget still admits the wake exactly once under one id"
}

test_reload_during_outage_keeps_the_pending_id() {
  v2_require_native outage-reload || return $?
  outage_case outage-reload 1
  pass "tui: a same-owner reload during an admission outage reconciles the pending wake under its original id"
}

# TUI exit: cleanup resolves only after its watcher retired; the episode is
# left recoverable (downtime) with the durable row intact, and the registration
# is retired while still protecting the exact session.
test_owner_exit_retires_supervision_and_keeps_wake_durable() {
  v2_require_native owner-exit || return $?
  tui_case owner-exit 1
  local out="$CASE/out.json" steps state="$HOME_DIR/state"
  steps=$(jq -nc --argjson l "$(lock_step)" --arg st "$state/alpha.status" --arg s "$state" \
    '[{do: "sleep", ms: 300}, $l, {do: "sleep", ms: 4000}, {do: "outage", ms: 600000},
      {do: "write", path: $st, text: "done: alpha finished\n"}, {do: "sleep", ms: 5000}, {do: "cleanup"},
      {do: "shell", command: ("p=$(cat " + $s + "/.watch.lock/pid 2>/dev/null); if [ -n \"$p\" ] && kill -0 \"$p\" 2>/dev/null; then echo watcher-live; else echo watcher-gone; fi; cat " + $s + "/.watcher-down; grep -c alpha " + $s + "/.wake-queue")},
      {do: "registration"}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s, cleanupAtEnd: false}')")" "$out"
  jq -e '.steps[6].ok' "$out" >/dev/null || fail "owner cleanup failed: $(jq -c '.steps[6]' "$out")"
  jq -e '.steps[7].stdout | test("watcher-gone")' "$out" >/dev/null || fail "owner cleanup resolved while its watcher was still live: $(jq -c '.steps[7]' "$out")"
  jq -e '.steps[7].stdout | test(":downtime:")' "$out" >/dev/null || fail "owner exit did not leave the unadmitted episode recoverable: $(jq -c '.steps[7]' "$out")"
  jq -e '.steps[7].stdout | test("\n[1-9]")' "$out" >/dev/null || fail "owner exit consumed the durable wake row: $(jq -c '.steps[7]' "$out")"
  jq -e '.steps[8].record.lifecycle == "retired"' "$out" >/dev/null || fail "owner exit did not retire the registration: $(jq -c '.steps[8]' "$out")"
  pass "tui: owner exit awaits watcher retirement, keeps the wake durable and recoverable, and retires the registration"
}

# M7: at turn end with supervision needed and no watcher, the owner arms a
# watcher within the bound and produces no prompt.
test_turn_end_arms_watcher_without_prompt() {
  v2_require_native turn-end || return $?
  tui_case turn-end 1
  local out="$CASE/out.json" steps
  steps=$(jq -nc --argjson l "$(lock_step)" --arg wl "$HOME_DIR/state/.watch.lock/pid" \
    '[{do: "sleep", ms: 300}, $l,
      {do: "event", event: {type: "session.execution.succeeded", data: {sessionID: "ses_lead"}}},
      {do: "sleep", ms: 5000}, {do: "shell", command: ("p=$(cat " + $wl + " 2>/dev/null); [ -n \"$p\" ] && kill -0 \"$p\" && echo armed")}]')
  v2_tui "$CASE" "$(spec "$(jq -nc --argjson s "$steps" '{steps: $s}')")" "$out"
  jq -e '.steps[4].stdout | test("armed")' "$out" >/dev/null || fail "no live watcher after turn end with supervision needed: $(jq -c '{s: .steps[4], failures}' "$out")"
  [ "$(jq '[.admitted[] | select(.text | test("fm-session-start") | not)] | length' "$out")" = 0 ] \
    || fail "turn end produced a prompt while a watcher could be armed: $(jq -c '.admitted' "$out")"
  pass "tui: turn end with supervision needed arms a watcher and produces no prompt"
}

# --- admission journal and coordinator (public module seams) ----------------

# M5 plus lost receipt: drive the production coordinator and journal directly
# with a stub arm whose handling confirmation reports an already-acknowledged
# episode, and an admit function that loses one acknowledgement.
journal_driver() {  # <dir> <mode> <out>
  local dir=$1
  mkdir -p "$dir/root/bin" "$dir/home/state" "$dir/home/config"
  cat > "$dir/root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then echo "watcher: recovery episode already acknowledged" >&2; exit 1; fi
trap 'exit 0' TERM
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
sleep 30 & wait
SH
  printf '#!/usr/bin/env bash\ncat\n' > "$dir/root/bin/fm-operational-input.sh"
  chmod +x "$dir/root/bin/"*.sh
  : > "$dir/home/config/x-mode.env"
  MODE=$2 "$V2_NODE_BIN" --input-type=module - "$V2_CODE_ROOT" "$dir" "$3" <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
const [codeRoot, dir, out] = process.argv.slice(2);
const { createWatchArmCoordinator } = await import(pathToFileURL(`${codeRoot}/.opencode/plugins/lib/fm-watch-arm-v2.js`).href);
const { createAdmissionJournal } = await import(pathToFileURL(`${codeRoot}/.opencode/plugins/fm-native-v2/admission.js`).href);
const paths = { root: `${dir}/root`, home: `${dir}/home`, state: `${dir}/home/state`, config: `${dir}/home/config` };
const attempts = [], admitted = new Set(), failures = [];
let lost = process.env.MODE === "lost-ack" ? 1 : 0, rejects = process.env.MODE === "reject" ? 2 : 0;
const admit = async (input) => {
  attempts.push(input.id);
  if (rejects > 0) { rejects -= 1; throw new Error("admission rejected"); }
  admitted.add(input.id);
  if (lost > 0) { lost -= 1; throw new Error("acknowledgement lost"); }
  return { id: input.id };
};
const journal = createAdmissionJournal(paths, "ses_lead", admit, (r) => failures.push(String(r)));
const result = { mode: process.env.MODE };
if (process.env.MODE === "acked") {
  const coordinator = createWatchArmCoordinator(paths, () => {}, { owns: () => true, admission: journal, failure: (r) => failures.push(String(r)) });
  // A prepared wake admission captured one canonical queue row; the lead then
  // drained and acknowledged it, so the canonical owner removed the row.
  const { writeFileSync: write } = await import("node:fs");
  write(`${paths.state}/.wake-queue`, "1700000000\t1\tsignal\talpha.status\tsignal: alpha\n");
  journal.prepare("pending wake text", "wake");
  result.pendingBefore = journal.pending().length;
  write(`${paths.state}/.wake-queue`, "");
  const errors = [];
  for (let i = 0; i < 3; i++) { try { await coordinator.resumePending("ses_lead"); } catch (e) { errors.push(String(e.message)); } }
  result.pendingAfter = journal.pending().length;
  result.errors = errors;
  await coordinator.cleanup().catch(() => {});
} else {
  const record = journal.prepare("wake text", "test:" + process.env.MODE);
  try { await journal.deliver(record); result.delivered = true; } catch (e) { result.delivered = false; result.error = String(e.message); }
  result.pendingAfter = journal.pending().length;
}
Object.assign(result, { attempts, admitted: [...admitted], failures });
writeFileSync(out, JSON.stringify(result));
process.exit(0);
EOF
}

test_pending_admission_retires_after_lead_ack() {
  v2_require_native acked-pending || return $?
  local dir="$TMP_ROOT/acked-pending"
  journal_driver "$dir" acked "$dir/out.json"
  jq -e '.pendingBefore == 1' "$dir/out.json" >/dev/null || fail "fixture vacuous: the wake admission was not pending before the lead acknowledged: $(cat "$dir/out.json")"
  jq -e '.pendingAfter == 0 and (.attempts | length) == 0' "$dir/out.json" >/dev/null \
    || fail "a pending admission whose rows the lead already acknowledged was not retired (or was admitted anyway): $(cat "$dir/out.json")"
  jq -e '(.errors | length) <= 1' "$dir/out.json" >/dev/null \
    || fail "a retired-episode admission keeps failing on every reconcile: $(jq -c .errors "$dir/out.json")"
  pass "tui: a pending admission whose episode was acknowledged is retired instead of failing forever"
}

test_lost_receipt_admits_once_without_failure() {
  v2_require_native lost-receipt || return $?
  local dir="$TMP_ROOT/lost-receipt"
  journal_driver "$dir" lost-ack "$dir/out.json"
  jq -e '.delivered and .pendingAfter == 0 and (.admitted | length) == 1 and (.attempts | unique | length) == 1 and (.failures | length) == 0' "$dir/out.json" >/dev/null \
    || fail "a lost admission receipt did not resolve to one admission under one id without a failure: $(cat "$dir/out.json")"
  pass "tui: a lost admission receipt resolves to one admission under one id with no failure report"
}

test_rejected_admissions_retry_one_id() {
  v2_require_native rejected-admission || return $?
  local dir="$TMP_ROOT/rejected-admission"
  journal_driver "$dir" reject "$dir/out.json"
  jq -e '.delivered and (.attempts | length) == 3 and (.attempts | unique | length) == 1 and (.admitted | length) == 1' "$dir/out.json" >/dev/null \
    || fail "rejected admissions did not retry under one stable id to one admission: $(cat "$dir/out.json")"
  pass "tui: rejected admissions retry under one stable id and admit once"
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
  test_same_tui_reload_does_not_renudge \
  test_startup_nudge_timeout_is_not_silently_dropped \
  test_routing_push_preserves_shell_environment \
  test_observer_environment_push_recovers \
  test_same_owner_republishes_after_service_restart \
  test_interrupt_alone_admits_nothing_but_a_genuine_wake_does \
  test_turn_end_arms_watcher_without_prompt \
  test_owner_exit_retires_supervision_and_keeps_wake_durable \
  test_admission_outage_never_strands_the_wake \
  test_reload_during_outage_keeps_the_pending_id \
  test_pending_admission_retires_after_lead_ack \
  test_lost_receipt_admits_once_without_failure \
  test_rejected_admissions_retry_one_id \
  test_worker_child_event_isolation
