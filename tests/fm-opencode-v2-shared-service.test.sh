#!/usr/bin/env bash
# Credential-free acceptance tests for OpenCode V2 / shuvcode supervision on
# the standard shared host service (issue #1).
#
# These tests drive the production plugin entrypoints and bin helpers. They
# model only host facts observed on shuvcode v2.0.22-shuv.1 against an
# isolated `serve --service` instance:
#   - one server process hosts every location; its process.env is the
#     environment of whichever client first started the service;
#   - every location instance receives the global event feed, including
#     session events for other locations;
#   - each plugin entry file evaluates its own copy of its local import graph,
#     so module-level state in a shared lib is not shared between plugin files;
#   - a tool subprocess's ancestry ends at `shuvcode serve --service` (reparented
#     to pid 1), with OPENCODE_SESSION_ID set by the server for that session.
# The host driver below reproduces those facts and nothing else; it does not
# reimplement shuvbro policy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-shared-service)
export NODE_NO_WARNINGS=1

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
}

# A private copy of the plugin directory, so its local import graph is a
# separate module instance, as shuvcode evaluates each plugin entry file.
plugin_copy() {
  local dest=$1
  mkdir -p "$dest"
  cp -R "$ROOT/.opencode/plugins/." "$dest/"
  printf '%s\n' "$dest"
}

passthrough_encoder() {
  cat > "$1/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$1/bin/fm-operational-input.sh"
}

# Multi-instance shared-server driver. spec.instances lists plugin entry files
# and the location directory each was loaded for; every event is broadcast to
# every instance (the global feed). session.prompt records each call and, when
# the request carries an id, admits it at most once (target idempotency).
drive_shared() {
  node --input-type=module - "$1" <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const spec = JSON.parse(process.argv[2]);
const sessions = new Map(Object.entries(spec.sessions || {}));
const attempts = [];
const admitted = [];
const admittedIDs = new Set();
let rejectBudget = spec.rejectPrompts || 0;
let lostAckBudget = spec.lostAckPrompts || 0;
const subscribers = [];

function makeCtx(directory) {
  const queue = [];
  let notify = null;
  const sub = { push(event) { queue.push(event); notify?.(); } };
  subscribers.push(sub);
  return {
    location: { directory, project: { directory, canonical: directory, id: "proj" } },
    event: {
      subscribe({ signal } = {}) {
        return {
          async *[Symbol.asyncIterator]() {
            while (!signal?.aborted) {
              if (queue.length) { yield queue.shift(); continue; }
              await new Promise((resolve) => {
                notify = resolve;
                signal?.addEventListener("abort", () => resolve(), { once: true });
              });
            }
          },
        };
      },
    },
    session: {
      async prompt(request) {
        attempts.push(request);
        if (rejectBudget > 0) {
          rejectBudget -= 1;
          throw new Error("admission rejected");
        }
        const duplicate = request.id && admittedIDs.has(request.id);
        if (!duplicate) {
          admitted.push(request);
          if (request.id) admittedIDs.add(request.id);
        }
        if (lostAckBudget > 0) {
          lostAckBudget -= 1;
          throw new Error("acknowledgement lost");
        }
        return { id: request.id || `msg_${attempts.length}` };
      },
      async get({ sessionID }) {
        if (!sessions.has(sessionID)) throw new Error("missing session");
        return sessions.get(sessionID);
      },
    },
  };
}

const cleanups = [];
for (const instance of spec.instances) {
  const mod = await import(pathToFileURL(instance.plugin).href);
  if (!mod.default || typeof mod.default.setup !== "function") throw new Error(`${instance.plugin}: missing V2 setup`);
  cleanups.push(await mod.default.setup(makeCtx(instance.directory)));
}
await new Promise((resolve) => setTimeout(resolve, 50));
for (const step of spec.events || []) {
  if (step.delayMs) await new Promise((resolve) => setTimeout(resolve, step.delayMs));
  if (step.event) for (const sub of subscribers) sub.push(step.event);
}
await new Promise((resolve) => setTimeout(resolve, spec.settleMs || 600));
for (const cleanup of cleanups) if (typeof cleanup === "function") await cleanup();
writeFileSync(spec.out, JSON.stringify({ attempts, admitted }));
process.exit(0);
EOF
}

# Every location loaded by one shared server sees the service-wide environment.
# If the plugin selects the home from that environment, a second primary on
# the same service supervises the first primary's home.
test_two_primaries_on_one_service_never_arm_one_home() {
  local a b home_a log out status
  a="$TMP_ROOT/two-primaries/a"
  b="$TMP_ROOT/two-primaries/b"
  home_a="$TMP_ROOT/two-primaries/home-a"
  make_primary "$a"
  make_primary "$b"
  mkdir -p "$home_a/state" "$home_a/config"
  : > "$home_a/state/task.meta"
  log="$TMP_ROOT/two-primaries/arm.log"
  for repo in "$a" "$b"; do
    cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$repo" "\${FM_HOME:-unset}" >> "$log"
trap 'exit 0' TERM
printf 'watcher: started pid=\$\$\n'
sleep 5 &
wait
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    passthrough_encoder "$repo"
    plugin_copy "$repo/.opencode/plugins" >/dev/null
  done
  # The lock names this driver process, which every instance descends from,
  # so the only thing separating the two homes is home selection itself.
  out="$TMP_ROOT/two-primaries/out.json"
  status=0
  FM_HOME="$home_a" drive_shared "$(jq -nc --arg a "$a" --arg b "$b" --arg out "$out" --arg lock "$home_a/state/.lock" '{
      out: $out,
      settleMs: 900,
      instances: [
        { plugin: ($a + "/.opencode/plugins/fm-primary-watch-arm.js"), directory: $a },
        { plugin: ($b + "/.opencode/plugins/fm-primary-watch-arm.js"), directory: $b }
      ],
      sessions: {
        ses_lead_a: { id: "ses_lead_a", location: { directory: $a } },
        ses_lead_b: { id: "ses_lead_b", location: { directory: $b } }
      },
      events: [
        { event: { type: "session.execution.succeeded", data: { sessionID: "ses_lead_a" } } },
        { event: { type: "session.execution.succeeded", data: { sessionID: "ses_lead_b" } } }
      ]
    }')" &
  local driver=$!
  printf '%s' "$driver" > "$home_a/state/.lock"
  wait "$driver" || status=$?
  expect_code 0 "$status" "shared-service driver"
  [ -f "$log" ] || fail "fixture vacuous: neither primary armed, so home selection was never exercised"
  local homes
  homes=$(awk -v h="$home_a" '$2 == h { print $1 }' "$log" | sort -u | wc -l | tr -d ' ')
  [ "$homes" -le 1 ] || fail "two primary locations on one shared service both armed home $home_a: $(cat "$log")"
  pass "shared service: two primary locations never both arm one home from the service-wide environment"
}

# shuvcode evaluates each plugin entry file with its own copy of its local
# imports, so a coordinator registered by the watch-arm plugin is invisible to
# a module-level lookup in the turn-end plugin. The backstop must still defer to
# the plugin-owned watcher instead of queuing a competing follow-up.
turnend_vs_armed_watcher() {  # <name> <isolated:0|1>
  local name=$1 isolated=$2 repo watch_plugins turnend_plugins out status
  repo="$TMP_ROOT/$name/primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
printf 'watcher: started pid=%s\n' "$$"
sleep 5 &
wait
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'supervision is off\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  passthrough_encoder "$repo"
  if [ "$isolated" = 1 ]; then
    watch_plugins=$(plugin_copy "$repo/.opencode/plugins")
    turnend_plugins=$(plugin_copy "$TMP_ROOT/$name/turnend-graph")
  else
    watch_plugins=$(plugin_copy "$repo/.opencode/plugins")
    turnend_plugins=$watch_plugins
  fi
  out="$TMP_ROOT/$name/out.json"
  status=0
  drive_shared "$(jq -nc --arg dir "$repo" --arg out "$out" \
    --arg w "$watch_plugins/fm-primary-watch-arm.js" --arg t "$turnend_plugins/fm-primary-turnend-guard.js" '{
      out: $out,
      settleMs: 900,
      instances: [ { plugin: $w, directory: $dir }, { plugin: $t, directory: $dir } ],
      sessions: { ses_lead: { id: "ses_lead", location: { directory: $dir } } },
      events: [
        { event: { type: "session.execution.started", data: { sessionID: "ses_lead" } } },
        { event: { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } } }
      ]
    }')" &
  local driver=$!
  printf '%s' "$driver" > "$repo/state/.lock"
  wait "$driver" || status=$?
  expect_code 0 "$status" "$name driver"
  RESULT=$(cat "$out")
}

test_turnend_defers_to_armed_watcher_in_one_module_graph() {
  turnend_vs_armed_watcher turnend-shared-graph 0
  printf '%s' "$RESULT" | jq -e '[.admitted[] | select(.text | test("TURN WOULD END BLIND"))] | length == 0' >/dev/null \
    || fail "turn-end queued a blind follow-up while the plugin-owned watcher was armed: $RESULT"
  pass "turn-end defers to the armed plugin watcher when both plugins share one module graph"
}

test_turnend_defers_to_armed_watcher_across_plugin_module_graphs() {
  turnend_vs_armed_watcher turnend-isolated-graph 1
  printf '%s' "$RESULT" | jq -e '[.admitted[] | select(.text | test("TURN WOULD END BLIND"))] | length == 0' >/dev/null \
    || fail "with shuvcode's per-plugin module graphs, turn-end could not see the watcher coordinator and queued a competing blind follow-up: $RESULT"
  pass "turn-end defers to the armed plugin watcher across shuvcode's per-plugin module graphs"
}

# An actionable watcher close whose wake admission fails transiently must not
# lose the wake; every retry must reuse one schema-valid message id so the
# target's first-admission-wins idempotency prevents duplicate execution.
actionable_wake_fixture() {  # <name>
  local name=$1 repo
  repo="$TMP_ROOT/$name/primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then exit 0; fi
count_file="$TMP_ROOT/$name/arms"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" > "\$count_file"
if [ "\$n" = 1 ]; then
  printf 'signal: task-alpha\n'
  exit 0
fi
trap 'exit 0' TERM
printf 'watcher: started pid=%s recovery-generation=gen-%s\n' "\$\$" "\$n"
sleep 5 &
wait
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  passthrough_encoder "$repo"
  plugin_copy "$repo/.opencode/plugins" >/dev/null
  printf '%s\n' "$repo"
}

run_actionable_wake() {  # <name> <spec-extra-json>
  local name=$1 extra=$2 repo out status
  repo=$(actionable_wake_fixture "$name")
  out="$TMP_ROOT/$name/out.json"
  status=0
  drive_shared "$(jq -nc --arg dir "$repo" --arg out "$out" --argjson extra "$extra" '{
      out: $out,
      settleMs: 2500,
      instances: [ { plugin: ($dir + "/.opencode/plugins/fm-primary-watch-arm.js"), directory: $dir } ],
      sessions: { ses_lead: { id: "ses_lead", location: { directory: $dir } } },
      events: [ { event: { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } } } ]
    } + $extra')" &
  local driver=$!
  printf '%s' "$driver" > "$repo/state/.lock"
  wait "$driver" || status=$?
  expect_code 0 "$status" "$name driver"
  RESULT=$(cat "$out")
  printf '%s' "$RESULT" | jq -e '[.attempts[] | select(.sessionID == "ses_lead")] | length >= 1' >/dev/null \
    || fail "fixture vacuous: the actionable close never reached prompt admission: $RESULT"
}

test_transient_admission_failure_does_not_lose_the_wake() {
  run_actionable_wake wake-retry '{"rejectPrompts": 1}'
  printf '%s' "$RESULT" | jq -e '[.admitted[] | select(.text | test("signal: task-alpha"))] | length == 1' >/dev/null \
    || fail "a transiently rejected wake admission lost the actionable reason (want exactly one admitted copy): $RESULT"
  printf '%s' "$RESULT" | jq -e '
      [.attempts[] | select(.text | test("signal: task-alpha")) | .id] as $ids
      | ($ids | length) >= 2 and ($ids | all(type == "string" and length > 0)) and ($ids | unique | length) == 1' >/dev/null \
    || fail "wake admission retries must reuse one non-empty message id: $RESULT"
  pass "a transient wake admission failure retries with one stable message id and admits the wake once"
}

test_lost_admission_acknowledgement_admits_one_copy() {
  run_actionable_wake wake-lost-ack '{"lostAckPrompts": 1}'
  printf '%s' "$RESULT" | jq -e '[.admitted[] | select(.text | test("signal: task-alpha"))] | length == 1' >/dev/null \
    || fail "a lost admission acknowledgement must leave exactly one admitted copy of the wake: $RESULT"
  printf '%s' "$RESULT" | jq -e '[.admitted[] | select(.text | test("could not deliver an actionable wake"))] | length == 0' >/dev/null \
    || fail "an admitted wake whose acknowledgement was lost was reported to the lead as undelivered: $RESULT"
  pass "a lost admission acknowledgement admits exactly one wake and is not reported as a delivery failure"
}

# Lock ownership from a lead tool subprocess on the standard shared service.
# The ancestry ends at the shared `serve --service` process, which is correctly
# never a session identity. A lead there must still be able to hold its own
# home's lock through exact session binding, and a second session on the same
# service must never take it. Binding evidence assumed by this fixture:
# OPENCODE_SESSION_ID, which the server sets on every shell tool invocation.
shared_service_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  "${FM_TEST_SERVICE_PID}:comm=") printf '%s\n' shuvcode ;;
  "${FM_TEST_SERVICE_PID}:args=") printf '%s\n' '/opt/shuvcode/bin/shuvcode serve --service' ;;
  "${FM_TEST_SERVICE_PID}:ppid=") printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' "$FM_TEST_SERVICE_PID" ;;
esac
SH
  chmod +x "$1/ps"
}

lock_as_session() {  # <home> <fakebin> <service-pid> <session-id>
  env -u FM_ROOT_OVERRIDE FM_HOME="$1" PATH="$2:$PATH" FM_TEST_SERVICE_PID="$3" OPENCODE_SESSION_ID="$4" \
    bash "$ROOT/bin/fm-lock.sh" 2>&1
}

test_shared_service_lead_holds_its_home_lock() {
  local dir home fakebin service out status
  dir="$TMP_ROOT/shared-lock"
  home="$dir/home"
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  shared_service_ps "$fakebin"
  sleep 30 &
  service=$!
  status=0
  out=$(lock_as_session "$home" "$fakebin" "$service" ses_lead) || status=$?
  if [ "$status" -ne 0 ]; then
    kill "$service" 2>/dev/null
    fail "a lead on the standard shared service could not acquire its own home lock: $out"
  fi
  status=0
  out=$(lock_as_session "$home" "$fakebin" "$service" ses_other) || status=$?
  kill "$service" 2>/dev/null
  [ "$status" -ne 0 ] || fail "a second session on the same shared service took a live lead's home lock: $out"
  pass "shared service: the lead session holds its home lock and another session on the service cannot take it"
}

test_shared_service_without_session_identity_never_locks() {
  local dir home fakebin service out status
  dir="$TMP_ROOT/shared-lock-anon"
  home="$dir/home"
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$dir")
  shared_service_ps "$fakebin"
  sleep 30 &
  service=$!
  status=0
  out=$(env -u OPENCODE_SESSION_ID -u FM_ROOT_OVERRIDE FM_HOME="$home" PATH="$fakebin:$PATH" FM_TEST_SERVICE_PID="$service" \
    bash "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  kill "$service" 2>/dev/null
  [ "$status" -ne 0 ] || fail "a shared-service process with no session identity acquired a home lock: $out"
  [ ! -s "$home/state/.lock" ] || [ "$(cat "$home/state/.lock")" != "$service" ] \
    || fail "the shared service pid was recorded as the home lock holder"
  pass "shared service: a process with no session identity never acquires a home lock or records the service pid"
}

FAILED=0
for t in \
  test_two_primaries_on_one_service_never_arm_one_home \
  test_turnend_defers_to_armed_watcher_in_one_module_graph \
  test_turnend_defers_to_armed_watcher_across_plugin_module_graphs \
  test_transient_admission_failure_does_not_lose_the_wake \
  test_lost_admission_acknowledgement_admits_one_copy \
  test_shared_service_lead_holds_its_home_lock \
  test_shared_service_without_session_identity_never_locks; do
  ( "$t" ) || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] || { printf 'not ok - %s shared-service acceptance case(s) failed\n' "$FAILED" >&2; exit 1; }
