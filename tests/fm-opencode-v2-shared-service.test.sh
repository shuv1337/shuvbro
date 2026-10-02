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

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

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
  tar -C "$ROOT/.opencode/plugins" --exclude=./node_modules -cf - . | tar -C "$dest" -xf -
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

# The shared server loads the primary's plugin again for every subdirectory
# location under it. An idle root session in a subdirectory of the primary is
# not the lead, so one home must still get at most one watcher arm.
test_subdirectory_location_never_adds_a_second_arm() {
  local repo sub log out status
  repo="$TMP_ROOT/subdir/primary"
  sub="$repo/sub"
  make_primary "$repo"
  mkdir -p "$sub"
  log="$TMP_ROOT/subdir/arm.log"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
printf 'arm %s\n' "\${FM_STATE_OVERRIDE:-unset}" >> "$log"
trap 'exit 0' TERM
printf 'watcher: started pid=%s\n' "\$\$"
sleep 5 &
wait
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  passthrough_encoder "$repo"
  plugin_copy "$repo/.opencode/plugins" >/dev/null
  plugin_copy "$TMP_ROOT/subdir/sub-graph" >/dev/null
  out="$TMP_ROOT/subdir/out.json"
  status=0
  drive_shared "$(jq -nc --arg dir "$repo" --arg sub "$sub" --arg out "$out" --arg g "$TMP_ROOT/subdir/sub-graph" '{
      out: $out,
      settleMs: 900,
      instances: [
        { plugin: ($dir + "/.opencode/plugins/fm-primary-watch-arm.js"), directory: $dir },
        { plugin: ($g + "/fm-primary-watch-arm.js"), directory: $sub }
      ],
      sessions: {
        ses_lead: { id: "ses_lead", location: { directory: $dir } },
        ses_adhoc: { id: "ses_adhoc", location: { directory: $sub } }
      },
      events: [
        { event: { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } } },
        { event: { type: "session.execution.succeeded", data: { sessionID: "ses_adhoc" } } }
      ]
    }')" &
  local driver=$!
  printf '%s' "$driver" > "$repo/state/.lock"
  wait "$driver" || status=$?
  expect_code 0 "$status" "subdirectory driver"
  [ -f "$log" ] || fail "fixture vacuous: no instance armed at all"
  [ "$(wc -l < "$log" | tr -d ' ')" -le 1 ] \
    || fail "a root session in a subdirectory of the primary added a second watcher arm for one home: $(cat "$log")"
  pass "shared service: a subdirectory location of the primary never adds a second watcher arm"
}

# An explicitly interrupted lead turn must not be resurrected by a
# self-generated follow-up: any prompt the adapter admits for that interruption
# must not schedule execution (resume:false), and the default is no prompt.
test_interrupted_turn_gets_no_self_generated_resuming_prompt() {
  local repo out status
  repo="$TMP_ROOT/interrupted/primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'supervision is off\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  passthrough_encoder "$repo"
  plugin_copy "$repo/.opencode/plugins" >/dev/null
  out="$TMP_ROOT/interrupted/out.json"
  status=0
  drive_shared "$(jq -nc --arg dir "$repo" --arg out "$out" '{
      out: $out,
      settleMs: 700,
      instances: [ { plugin: ($dir + "/.opencode/plugins/fm-primary-turnend-guard.js"), directory: $dir } ],
      sessions: { ses_lead: { id: "ses_lead", location: { directory: $dir } } },
      events: [
        { event: { type: "session.execution.started", data: { sessionID: "ses_lead" } } },
        { event: { type: "session.execution.interrupted", data: { sessionID: "ses_lead" } } }
      ]
    }')" &
  local driver=$!
  printf '%s' "$driver" > "$repo/state/.lock"
  wait "$driver" || status=$?
  expect_code 0 "$status" "interrupted driver"
  jq -e '[.admitted[] | select(.sessionID == "ses_lead" and .resume != false)] | length == 0' "$out" >/dev/null \
    || fail "an explicitly interrupted lead turn received a self-generated prompt that schedules execution: $(cat "$out")"
  pass "an explicitly interrupted lead turn gets no self-generated prompt that resumes execution"
}

# The plugin cases above drive the pre-native server entries. Once the native
# V2 package exists in this tree those entries are no longer the lead's
# lifecycle owner; the same invariants run against the native TUI entry, with
# positive controls, in tests/fm-opencode-v2-tui-acceptance.test.sh.
legacy_case() {  # <case-function>
  if [ -f "$ROOT/.opencode/plugins/fm-native-v2/tui.js" ]; then
    printf 'skip - %s: superseded by tests/fm-opencode-v2-tui-acceptance.test.sh (native V2 entry present)\n' "$1"
    return 0
  fi
  "$1"
}

FAILED=0
for t in \
  test_subdirectory_location_never_adds_a_second_arm \
  test_interrupted_turn_gets_no_self_generated_resuming_prompt \
  test_two_primaries_on_one_service_never_arm_one_home \
  test_turnend_defers_to_armed_watcher_in_one_module_graph \
  test_turnend_defers_to_armed_watcher_across_plugin_module_graphs; do
  ( legacy_case "$t" ) || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] || { printf 'not ok - %s shared-service acceptance case(s) failed\n' "$FAILED" >&2; exit 1; }
