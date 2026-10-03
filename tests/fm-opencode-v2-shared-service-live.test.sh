#!/usr/bin/env bash
# Live qualification of OpenCode V2 supervision on a real, isolated shuvcode
# shared service (issue #1 "Required live qualification").
#
# Run with FM_OPENCODE_V2_SHARED_LIVE=1. It starts a disposable `serve --service`
# under relocated XDG roots on a free loopback port, verifies with
# `debug paths` that config, state and data are all inside the lab before any
# service command, and stops that service in its exit trap. It never touches the
# operator's service, configuration or sessions.
#
# Model turns come from a local deterministic OpenAI-compatible mock provider,
# so real execution events and real shell tool calls run on the real host
# without model spend. The mock is a verification tool, not a product
# guarantee: a final real-model run remains part of qualification.
#
# Phases:
#   1. isolation and service identity
#   2. plugin inventory for the disposable primary: no failed or duplicate plugins
#   3. real-host guard scope: an unrelated root session and a child of the lead
#      run a protected command (marker created); the exact-marked lead is refused
#      by the typed rejection (marker absent)
#   4. lead model-shell identity on the shared service: server-set session id,
#      shared-service parent, and lock refusal without registration
#   5. pending until the frozen interfaces land: registered lead lock, two homes,
#      TUI owner, observer client, Herdr detach/attach (bin/fm-herdr-lab.sh)
# Evidence is retained under the lab directory on failure.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"
fm_live_gate opt-in FM_OPENCODE_V2_SHARED_LIVE shuvcode jq node git curl

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-v2-shared-live.XXXXXX")
LAB=$(cd -P "$LAB" && pwd -P)
MOCK_PID=
SC=
SERVICE_STARTED=0
LIVE_FAILED=0

# Relocated XDG roots break version-manager shims (a mise node shim refuses
# untrusted config), which would make the guard helpers fail open inside the
# isolated service. Put the real node directory first so the service's helper
# subprocesses evaluate exactly as on the operator's host.
NODE_DIR=$(dirname "$(node -p process.execPath)")
ISO=(env -u OPENCODE_CONFIG_DIR -u OPENCODE_SESSION_ID -u OPENCODE -u OPENCODE_TERMINAL
  -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_V2_ACTIVATION
  -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV
  PATH="$NODE_DIR:$PATH" XDG_CONFIG_HOME="$LAB/xdg/config" XDG_STATE_HOME="$LAB/xdg/state"
  XDG_DATA_HOME="$LAB/xdg/data" XDG_CACHE_HOME="$LAB/xdg/cache")
isolated() { "${ISO[@]}" "$@"; }
export TERMCTRL_RUNTIME_DIR="$LAB/tc"
mkdir -p "$TERMCTRL_RUNTIME_DIR"
TERMS=()

cleanup() {
  local status=$? reg_pid='' term
  for term in "${TERMS[@]}"; do termctrl stop "$term" >/dev/null 2>&1 || true; done
  if [ "$SERVICE_STARTED" = 1 ]; then
    reg_pid=$(jq -r '.pid // empty' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null)
    (cd "$LAB" && isolated "$SC" service stop >/dev/null 2>&1) || true
    if [ -n "$reg_pid" ] && kill -0 "$reg_pid" 2>/dev/null; then
      printf 'not ok - isolated service pid %s survived service stop\n' "$reg_pid" >&2
      status=1
    fi
  fi
  [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null
  v2_teardown
  if [ "$status" -eq 0 ] && [ "$LIVE_FAILED" -eq 0 ]; then
    rm -rf "$LAB"
  else
    printf 'note: live evidence retained at %s\n' "$LAB" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT

live_fail() { printf 'not ok - %s\n' "$1" >&2; LIVE_FAILED=$((LIVE_FAILED + 1)); }

# The node launcher cannot run with relocated XDG config on hosts whose node
# resolves through a config-trusting shim, so drive the platform binary.
resolve_binary() {
  local launcher dir candidate
  if [ -n "${FM_OPENCODE_V2_BIN:-}" ]; then printf '%s' "$FM_OPENCODE_V2_BIN"; return; fi
  launcher=$(readlink -f "$(command -v shuvcode)")
  dir=$(dirname "$launcher")
  for candidate in "$dir"/../node_modules/shuvcode-*/bin/shuvcode "$dir"/../../shuvcode-*/bin/shuvcode; do
    [ -x "$candidate" ] && { readlink -f "$candidate"; return; }
  done
  printf '%s' "$launcher"
}

free_port() {
  node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'
}

# --- phase 1: isolation and service identity --------------------------------
SC=$(resolve_binary)
VERSION=$("$SC" --version 2>/dev/null)
mkdir -p "$LAB/xdg/config" "$LAB/xdg/state" "$LAB/xdg/data" "$LAB/xdg/cache"
paths=$(cd "$LAB" && isolated "$SC" debug paths 2>/dev/null)
for kind in config state data; do
  value=$(printf '%s\n' "$paths" | awk -v k="$kind" '$1 == k { print $2 }')
  case "$value" in
    "$LAB"/*) ;;
    *) fail "isolation refused: shuvcode $kind path '$value' is outside the lab; no service command was run" ;;
  esac
done
SERVICE_PORT=$(free_port)
MOCK_PORT=$(free_port)

cat > "$LAB/mock.mjs" <<'EOF'
// Deterministic OpenAI-compatible chat mock. A user message containing
// "RUN: <command>" yields one shell tool call; any other turn ends with text.
import http from "node:http";
import { appendFileSync } from "node:fs";
const [port, log] = process.argv.slice(2);
const text = (content) => (typeof content === "string" ? content : (content || []).map((p) => p.text || "").join(""));
http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    if (!req.url.includes("chat/completions")) { res.writeHead(404); res.end(); return; }
    let parsed = {};
    try { parsed = JSON.parse(body); } catch {}
    const messages = parsed.messages || [];
    const lastUser = [...messages].reverse().find((m) => m.role === "user");
    const lastIsTool = messages.length > 0 && messages[messages.length - 1].role === "tool";
    const userText = lastUser ? text(lastUser.content) : "";
    // The startup nudge from a real activated TUI maps to the minimal canonical
    // ownership step (MOCK_STARTUP_CMD), so the lead acquires its home lock.
    // A watcher wake maps to the canonical handling step (MOCK_WAKE_CMD: real
    // drain plus generation-bound acknowledgement, recorded per success).
    const match = /RUN: ([^\n]+)/.exec(userText)
      || (process.env.MOCK_WAKE_CMD && userText.includes("WATCHER FIRED") ? [null, process.env.MOCK_WAKE_CMD] : null)
      // shuvcode's restart continuation for a suspended turn (leg H).
      || (process.env.MOCK_RESUME_CMD && /server restarted/i.test(userText) ? [null, process.env.MOCK_RESUME_CMD] : null)
      || (process.env.MOCK_STARTUP_CMD && userText.includes("bin/fm-session-start.sh") ? [null, process.env.MOCK_STARTUP_CMD] : null);
    const tools = (parsed.tools || []).map((t) => t.function?.name);
    appendFileSync(log, JSON.stringify({ messages: messages.length, lastIsTool, run: match ? match[1] : null }) + "\n");
    res.writeHead(200, { "content-type": "text/event-stream" });
    const send = (o) => res.write(`data: ${JSON.stringify(o)}\n\n`);
    const base = { id: "mock", object: "chat.completion.chunk", created: 1, model: "echo" };
    if (match && !lastIsTool && tools.includes("shell")) {
      send({ ...base, choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: `call_${Date.now()}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ command: match[1], description: "live probe" }) } }] }, finish_reason: null }] });
      send({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] });
    } else {
      send({ ...base, choices: [{ index: 0, delta: { role: "assistant", content: "ok" }, finish_reason: null }] });
      send({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } });
    }
    res.write("data: [DONE]\n\n");
    res.end();
  });
}).listen(Number(port), "127.0.0.1");
EOF
# shellcheck disable=SC2016 # expanded by the lead model shell
MOCK_WAKE_CMD='err=$(bin/fm-wake-drain.sh 2>&1 >/dev/null); seq=$(printf "%s\n" "$err" | sed -n "s/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p"); gen=$(printf "%s\n" "$err" | sed -n "s/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p"); [ -n "$seq" ] && [ -n "$gen" ] && bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" && printf "acked %s %s\n" "$seq" "$(date +%s%N)" >> '"$LAB"'/handled.log'
# Worker H's resumed turn runs on; worker H2's resumed turn finishes by itself.
MOCK_RESUME_CMD="case \"\$PWD\" in */worker-h2) date +%s%N >> $LAB/h2.resumed ;; *) date +%s%N >> $LAB/h.resumed; while :; do date +%s%N > $LAB/h.beat; sleep 0.3; done ;; esac"
MOCK_STARTUP_CMD='bash bin/fm-lock.sh' MOCK_WAKE_CMD="$MOCK_WAKE_CMD" MOCK_RESUME_CMD="$MOCK_RESUME_CMD" node "$LAB/mock.mjs" "$MOCK_PORT" "$LAB/mock.log" >/dev/null 2>&1 &
MOCK_PID=$!

mkdir -p "$LAB/xdg/config/shuvcode"
jq -n --arg url "http://127.0.0.1:$MOCK_PORT/v1" '{
  providers: { mock: { name: "Mock", env: ["FM_LIVE_MOCK_KEY"], package: "@opencode/ai/providers/openai-compatible",
    settings: { baseURL: $url, apiKey: "mock" }, models: { echo: { name: "Echo" } } } },
  model: "mock/echo"
}' > "$LAB/xdg/config/shuvcode/opencode.json"
(cd "$LAB" && isolated "$SC" service set port "$SERVICE_PORT" >/dev/null) || fail "could not configure the isolated service port"
(cd "$LAB" && isolated FM_LIVE_MOCK_KEY=mock FM_LIVE_FIRST_CLIENT=first-client "$SC" service start >/dev/null 2>&1) \
  || fail "isolated service did not start"
SERVICE_STARTED=1
SERVICE_PID=$(jq -r '.pid' "$LAB/xdg/state/shuvcode/service.json")
case "$(ps -o args= -p "$SERVICE_PID" 2>/dev/null)" in
  *serve*--service*) ;;
  *) fail "registered isolated service pid $SERVICE_PID is not a serve --service process" ;;
esac
pass "live phase 1: isolated shared service $VERSION pid $SERVICE_PID on port $SERVICE_PORT with all paths in the lab"

api() {  # <method> <path> [json]
  if [ -n "${3:-}" ]; then
    (cd "$LAB" && isolated "$SC" api "$1" "$2" --data "$3" 2>/dev/null)
  else
    (cd "$LAB" && isolated "$SC" api "$1" "$2" 2>/dev/null)
  fi
}

make_live_primary() {  # <dir>
  local dir=$1
  mkdir -p "$dir/.opencode" "$dir/state" "$dir/config" "$dir/projects/x"
  git init -q "$dir"
  cp -R "$ROOT/bin" "$dir/bin"
  cp "$ROOT/AGENTS.md" "$dir/AGENTS.md"
  mkdir -p "$dir/.opencode/plugins"
  tar -C "$ROOT/.opencode/plugins" --exclude=./node_modules -cf - . | tar -C "$dir/.opencode/plugins" -xf -
  [ ! -d "$ROOT/.opencode/plugins/node_modules" ] || ln -s "$ROOT/.opencode/plugins/node_modules" "$dir/.opencode/plugins/node_modules"
}

create_session() {  # <directory> [parent-id] [metadata-json]
  local body
  body=$(jq -nc --arg d "$1" --arg p "${2:-}" --argjson m "${3:-null}" '{
      title: "live", location: {directory: $d}, model: {providerID: "mock", id: "echo"},
      permissions: [{action: "shell", resource: "*", effect: "allow"}]
    } + (if $p == "" then {} else {parentID: $p} end) + (if $m == null then {} else {metadata: $m} end)')
  api post /api/session "$body" | jq -r '.data.id'
}

# Prompt one RUN command into a session and wait until that turn settled: the
# session transcript ends idle after a user message carrying exactly this text.
run_in_session() {  # <session-id> <command> [unused]
  local text="RUN: $2"
  api post "/api/session/$1/prompt" "$(jq -nc --arg t "$text" '{text: $t, delivery: "queue"}')" >/dev/null \
    || { live_fail "prompt admission failed for $1"; return 1; }
  for _ in $(seq 1 150); do
    api get "/api/experimental/session/$1/export" > "$LAB/transcript-$1.json" 2>/dev/null || true
    if jq -e --arg t "$text" '.data.messages as $m
        | ([$m | to_entries[] | select(.value.type == "user" and .value.text == $t) | .key] | max) as $u
        | $u != null and ([$m | to_entries[] | select(.value.type == "idle") | .key] | max // -1) > $u' \
        "$LAB/transcript-$1.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  live_fail "session $1 did not complete its live tool turn for: $2"
  return 1
}

# The exact-session terminal evidence for one tool call: its recorded status and
# error message in that session's transcript.
tool_state() {  # <session-id> <command>
  jq -c --arg c "$2" '[.data.messages[]? | select(.type == "assistant") | .content[]? | select(.type == "tool" and .state.input.command == $c) | .state] | last | {status, error: (.error.message // null)}' \
    "$LAB/transcript-$1.json" 2>/dev/null
}

# --- phase 2: plugin inventory ----------------------------------------------
PRIMARY="$LAB/primary"
make_live_primary "$PRIMARY"

# Issue #1 pre-dispatch probe on the actual target: the installed executable
# and the primary's real pinned runtime qualify; the same executable with a
# code root lacking that runtime refuses with the actionable install step.
probe=$( (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-capability.mjs" "$PRIMARY") 2>&1)
if printf '%s' "$probe" | jq -e --arg v "$VERSION" '.qualified == true and .version == $v' >/dev/null 2>&1; then
  pass "live phase 1: the dispatch capability probe qualifies the installed $VERSION with the primary's pinned runtime"
else
  live_fail "the dispatch capability probe refused the installed target: $probe"
fi
mkdir -p "$LAB/no-runtime/.opencode/plugins"
cp "$PRIMARY/.opencode/plugins/package.json" "$LAB/no-runtime/.opencode/plugins/package.json"
if probe=$( (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-capability.mjs" "$LAB/no-runtime") 2>&1); then
  live_fail "the capability probe qualified a code root without the pinned runtime: $probe"
elif printf '%s' "$probe" | grep -q 'npm ci --prefix .opencode/plugins'; then
  pass "live phase 1: with the installed executable, a code root lacking the pinned runtime is refused with the install step"
else
  live_fail "the capability probe refused a runtime-less root without the actionable diagnostic: $probe"
fi
# The first request boots the location; local plugins finish loading after it.
for _ in $(seq 1 50); do
  inventory=$(api get "/api/plugin?location[directory]=$PRIMARY")
  [ "$(printf '%s' "$inventory" | jq '[.data[] | select(.source.type != "builtin")] | length')" -gt 0 ] && break
  sleep 0.2
done
printf '%s\n' "$inventory" > "$LAB/plugin-inventory.json"
local_plugins=$(printf '%s' "$inventory" | jq '[.data[] | select(.source.type != "builtin")] | length')
[ "$local_plugins" -gt 0 ] || live_fail "fixture vacuous: no local plugin loaded for the primary"
failed=$(printf '%s' "$inventory" | jq '[.data[] | select(.state.status == "failed")] | length')
dupes=$(printf '%s' "$inventory" | jq '[.data[].id] | group_by(.) | map(select(length > 1)) | length')
if [ "$failed" = 0 ] && [ "$dupes" = 0 ]; then
  pass "live phase 2: the primary's plugin inventory has no failed or duplicate plugins"
else
  live_fail "plugin inventory: $failed failed, $dupes duplicate ids ($(printf '%s' "$inventory" | jq -c '[.data[] | select(.source.type != "builtin") | {id, state: .state.status}]'))"
fi
# The native package's plugin id, read from its published entry when present.
[ -n "${FM_V2_TEST_LEAD_PLUGIN_ID:-}" ] || [ ! -f "$ROOT/.opencode/plugins/fm-native-v2/server.js" ] || FM_V2_TEST_LEAD_PLUGIN_ID=firstmate.native.v2
if [ -n "${FM_V2_TEST_LEAD_PLUGIN_ID:-}" ]; then
  count=$(printf '%s' "$inventory" | jq --arg id "$FM_V2_TEST_LEAD_PLUGIN_ID" '[.data[] | select(.id == $id and .state.status == "active")] | length')
  if [ "$count" = 1 ]; then pass "live phase 2: exactly one active V2 lead implementation ($FM_V2_TEST_LEAD_PLUGIN_ID)"
  else live_fail "expected exactly one active V2 lead implementation $FM_V2_TEST_LEAD_PLUGIN_ID, found $count"; fi
else
  printf 'pending - live single-lead-implementation inventory: integration pending (set FM_V2_TEST_LEAD_PLUGIN_ID)\n'
fi

# --- phase 3: real-host guard scope -----------------------------------------
PROTECT_PREFIX='cd projects/x && touch'
LEAD=$(create_session "$PRIMARY" "" '{"firstmateV2Lead":{"version":1,"sessionID":"PLACEHOLDER","claimID":"claim_live"}}')
api patch "/api/session/$LEAD" "$(jq -nc --arg s "$LEAD" '{metadata: {firstmateV2Lead: {version: 1, sessionID: $s, claimID: "claim_live"}}}')" >/dev/null
UNRELATED=$(create_session "$PRIMARY")
CHILD=$(create_session "$PRIMARY" "$LEAD")
[ -n "$LEAD" ] && [ -n "$UNRELATED" ] && [ -n "$CHILD" ] && [ "$LEAD" != null ] || fail "could not create live sessions"
api get "/api/session/$CHILD" | jq -e --arg s "$LEAD" '.data.metadata.firstmateV2Lead.sessionID == $s' >/dev/null \
  || live_fail "fixture: the child did not inherit the lead marker, so the inherited-marker case is vacuous"
turns=0
for pair in "unrelated:$UNRELATED" "child:$CHILD" "lead:$LEAD"; do
  name=${pair%%:*}
  sid=${pair#*:}
  turns=$((turns + 1))
  run_in_session "$sid" "$PROTECT_PREFIX $LAB/marker-$name" "$turns" || true
done
if [ -e "$LAB/marker-unrelated" ]; then pass "live phase 3: an unrelated root session at the primary ran the protected command"
else live_fail "live guard scope: an unrelated root session at the primary was refused lead-only policy"; fi
if [ -e "$LAB/marker-child" ]; then pass "live phase 3: a child carrying the inherited marker ran the protected command"
else live_fail "live guard scope: a child with an inherited marker was refused lead-only policy"; fi
lead_state=$(tool_state "$LEAD" "$PROTECT_PREFIX $LAB/marker-lead")
if [ ! -e "$LAB/marker-lead" ] && printf '%s' "$lead_state" | jq -e '.status == "error" and (.error | test("rebind"))' >/dev/null; then
  pass "live phase 3: the exact-marked unregistered lead's command was refused with the stale-scope rebind diagnostic before execution"
else live_fail "live guard scope: exact-marked unregistered lead: marker=$([ -e "$LAB/marker-lead" ] && echo present || echo absent) tool=$lead_state"; fi

# --- phase 4: model-shell identity on the shared service ---------------------
# Probed in the unrelated root session: an exact-marked lead without a valid
# registration is (correctly) refused every shell command.
turns=$((turns + 1))
run_in_session "$UNRELATED" "printf '%s %s %s\\n' \"\$OPENCODE_SESSION_ID\" \"\$(ps -o ppid= -p \$\$ | tr -d ' ')\" \"\${FM_LIVE_FIRST_CLIENT:-none}\" > $LAB/lead-identity; bash bin/fm-lock.sh > $LAB/lead-lock 2>&1; echo \"rc=\$?\" >> $LAB/lead-lock" "$turns" || true
if read -r id_session id_parent id_env < "$LAB/lead-identity" 2>/dev/null; then
  # Host fact the credential-free suites model: with no client-pushed session
  # environment, a model shell inherits the environment of whichever client
  # started the shared service, so ambient FM_* there can never be authority.
  [ "$id_env" = first-client ] \
    || live_fail "host fact changed: an API-created session's shell no longer inherits the service starter's environment (got '$id_env')"
  [ "$id_session" = "$UNRELATED" ] || live_fail "model shell OPENCODE_SESSION_ID was '$id_session', expected $UNRELATED"
  case "$(ps -o args= -p "$id_parent" 2>/dev/null)" in
    *serve*--service*) ;;
    *) live_fail "lead shell parent $id_parent is not the shared service" ;;
  esac
  grep -q '^rc=0$' "$LAB/lead-lock" && live_fail "an unregistered session acquired the home lock: $(cat "$LAB/lead-lock")"
  pass "live phase 4: a model shell carries its exact session id under the shared service and cannot lock unregistered"
else
  live_fail "lead identity probe did not run"
fi

# --- phase 5: real owner matrix ---------------------------------------------
# Real native TUIs activated through bin/fm-opencode-v2-primary.sh in PTYs,
# real workers through bin/fm-opencode-v2-launch.sh, an observer TUI, a
# service restart with the owner's /firstmate-rebind, and the Herdr leg with
# the real owner. Model turns come from the mock; the startup nudge maps to the
# minimal canonical ownership step (bin/fm-lock.sh).
owner() {  # <primary> <op> <arg...>
  local primary=$1
  shift
  isolated FM_V2_REGISTRY_NAMESPACE="$FM_V2_REGISTRY_NAMESPACE" node "$primary/bin/fm-opencode-v2-owner.mjs" "$@" 2>/dev/null
}
record_field() { owner "$1" read "$2" | jq -r --arg f "$3" '.[$f] // empty'; }
live_pid() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
wait_until() {  # <tries> <command...>
  local n=$1
  shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.5; n=$((n - 1)); done
  return 1
}
lead_active() {  # <primary> <home> <session>
  [ "$(record_field "$1" "$3" lifecycle)" = active ] \
    && [ "$(cat "$2/state/.lock" 2>/dev/null)" = "$(record_field "$1" "$3" ownerPID)" ] \
    && live_pid "$(cat "$2/state/.watch.lock/pid" 2>/dev/null)"
}
lead_command() {  # <primary> <home> <session>: the activation launch as argv
  printf '%s\n' "${ISO[@]}" FM_HOME="$2" FM_STATE_OVERRIDE="$2/state" FM_CONFIG_OVERRIDE="$2/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
    FM_V2_REGISTRY_NAMESPACE="$FM_V2_REGISTRY_NAMESPACE" bash "$1/bin/fm-opencode-v2-primary.sh" --session "$3" --native-binary "$SC"
}
launch_lead() {  # <term> <primary> <home> <session>
  local -a argv
  mapfile -t argv < <(lead_command "$2" "$3" "$4")
  termctrl start "$1" --cols 140 --rows 40 -- "${argv[@]}" >/dev/null || return 1
  TERMS+=("$1")
}
# Workers are task-bound like fm-spawn's: <task>.opencode-v2-session.json beside
# a safe <task>.meta, in a private directory no supervised home watches.
worker_task() {  # <name>
  [ -d "$LAB/workers" ] || mkdir -m 700 "$LAB/workers"
  printf 'kind=ship\nharness=opencode-v2\n' > "$LAB/workers/$1.meta"
}
make_home() {  # <dir>: external home with one in-flight task record (supervision need)
  mkdir -p "$1/state" "$1/config" "$1/data"
  printf 'kind=ship\n' > "$1/state/t1.meta"
  (cd -P "$1" && pwd -P)
}

# FM_V2_LIVE_LEGS (e.g. "AF") runs a subset while developing; leg A is the
# lead every other leg builds on and always runs.
leg() { [ -z "${FM_V2_LIVE_LEGS:-}" ] || [[ "$FM_V2_LIVE_LEGS" == *"$1"* ]]; }

# Leg A: registered lead with a real activated UI.
HOME_A=$(make_home "$LAB/home-a")
LEAD_A=$(create_session "$PRIMARY")
launch_lead lead-a "$PRIMARY" "$HOME_A" "$LEAD_A" || live_fail "could not start the lead UI in a PTY"
if wait_until 120 lead_active "$PRIMARY" "$HOME_A" "$LEAD_A"; then
  OWNER_A=$(record_field "$PRIMARY" "$LEAD_A" ownerPID)
  case "$(ps -o args= -p "$OWNER_A")" in
    "$SC"*) pass "live leg A: activated UI pid $OWNER_A owns lead $LEAD_A: active registration, .lock is the UI pid, watcher armed" ;;
    *) live_fail "registered owner pid $OWNER_A is not the native UI binary: $(ps -o args= -p "$OWNER_A")" ;;
  esac
  [ "$OWNER_A" != "$SERVICE_PID" ] || live_fail ".lock names the shared service"
  run_in_session "$LEAD_A" "touch $LAB/reg-allow" || true
  allow_state=$(tool_state "$LEAD_A" "touch $LAB/reg-allow")
  run_in_session "$LEAD_A" "cd projects/x && touch $LAB/reg-deny" || true
  deny_state=$(tool_state "$LEAD_A" "cd projects/x && touch $LAB/reg-deny")
  run_in_session "$LEAD_A" "echo ok; bin/fm-watch-arm.sh --restart &" || true
  arm_state=$(tool_state "$LEAD_A" "echo ok; bin/fm-watch-arm.sh --restart &")
  if [ -e "$LAB/reg-allow" ] && printf '%s' "$allow_state" | jq -e '.status == "completed"' >/dev/null \
    && [ ! -e "$LAB/reg-deny" ] && printf '%s' "$deny_state" | jq -e '.status == "error" and (.error | test("^\\[persistent-cd\\] "))' >/dev/null \
    && printf '%s' "$arm_state" | jq -e '.status == "error" and (.error | test("^\\[watcher-background\\] "))' >/dev/null; then
    pass "live leg A: in one lead session the allowed command completed, cd was rejected as [persistent-cd] and the backgrounded arm as [watcher-background], before execution"
  else
    live_fail "registered lead guard: allow=$allow_state marker=$([ -e "$LAB/reg-allow" ] && echo present || echo absent) deny=$deny_state deny-marker=$([ -e "$LAB/reg-deny" ] && echo present || echo absent) arm=$arm_state"
  fi
else
  live_fail "lead A never became active: record=$(owner "$PRIMARY" read "$LEAD_A") lock=$(cat "$HOME_A/state/.lock" 2>/dev/null) failure=$(cat "$HOME_A/state/.opencode-v2-failure.json" 2>/dev/null)"
  termctrl show lead-a > "$LAB/lead-a-screen.txt" 2>&1 || true
fi

# Leg B: a second home on the same service.
if leg B; then
PRIMARY_B="$LAB/primary-b"
make_live_primary "$PRIMARY_B"
HOME_B=$(make_home "$LAB/home-b")
LEAD_B=$(create_session "$PRIMARY_B")
launch_lead lead-b "$PRIMARY_B" "$HOME_B" "$LEAD_B" || live_fail "could not start lead B"
if wait_until 120 lead_active "$PRIMARY_B" "$HOME_B" "$LEAD_B"; then
  OWNER_B=$(record_field "$PRIMARY_B" "$LEAD_B" ownerPID)
  [ "$OWNER_B" != "${OWNER_A:-}" ] || live_fail "two homes share one owner pid"
  run_in_session "$LEAD_A" "FM_HOME=$HOME_B FM_STATE_OVERRIDE=$HOME_B/state FM_CONFIG_OVERRIDE=$HOME_B/config bash bin/fm-lock.sh; echo rc=\$? > $LAB/cross-home" || true
  if grep -q '^rc=0$' "$LAB/cross-home" 2>/dev/null || [ "$(cat "$HOME_B/state/.lock")" != "$OWNER_B" ]; then
    live_fail "lead A's shell took or disturbed home B's lock: $(cat "$LAB/cross-home" 2>/dev/null) lockB=$(cat "$HOME_B/state/.lock")"
  else
    pass "live leg B: two homes on one service each have their own active owner; lead A cannot take home B"
  fi
else
  live_fail "lead B never became active: $(owner "$PRIMARY_B" read "$LEAD_B")"
fi
fi

# Leg C: two workers on the shared service.
if leg C; then
# Worker 1 names its model; worker 2 relies on the lab's configured default
# (mock/echo), which must win over the native model.default fallback (D3).
for w in 1 2; do
  WDIR="$LAB/worker-$w"
  mkdir -p "$WDIR"
  git init -q "$WDIR"
  worker_task "worker-$w"
  model_arg="--model mock/echo"
  [ "$w" = 2 ] && model_arg=""
  termctrl start "worker-$w" --cols 120 --rows 30 -- "${ISO[@]}" bash -c \
    "cd '$WDIR' && exec '$PRIMARY/bin/fm-opencode-v2-launch.sh' $model_arg --prompt 'RUN: touch $LAB/worker-$w-ran' --session-record '$LAB/workers/worker-$w.opencode-v2-session.json'" >/dev/null \
    || live_fail "could not start worker $w"
  TERMS+=("worker-$w")
done
workers_ran() { [ -e "$LAB/worker-1-ran" ] && [ -e "$LAB/worker-2-ran" ]; }
if wait_until 120 workers_ran; then
  W1=$(jq -r .sessionID "$LAB/workers/worker-1.opencode-v2-session.json"); W2=$(jq -r .sessionID "$LAB/workers/worker-2.opencode-v2-session.json")
  [ "$W1" != "$W2" ] && [ -n "$W1" ] || live_fail "workers did not record distinct exact sessions"
  for w in 1 2; do
    jq -e '.model.providerID == "mock" and .model.id == "echo"' "$LAB/workers/worker-$w.opencode-v2-session.json" >/dev/null \
      || live_fail "worker $w ran on model $(jq -c .model "$LAB/workers/worker-$w.opencode-v2-session.json"), not the explicit/configured mock/echo"
  done
  [ "$(jq -r .pid "$LAB/xdg/state/shuvcode/service.json")" = "$SERVICE_PID" ] || live_fail "a worker started another service"
  run_in_session "$W1" "FM_HOME=$HOME_A FM_STATE_OVERRIDE=$HOME_A/state FM_CONFIG_OVERRIDE=$HOME_A/config FM_ROOT_OVERRIDE=$PRIMARY OPENCODE_SESSION_ID=$LEAD_A bash $PRIMARY/bin/fm-lock.sh; echo rc=\$? > $LAB/worker-claim" || true
  if grep -q '^rc=0$' "$LAB/worker-claim" 2>/dev/null; then
    live_fail "a worker shell claimed the lead's home through the shared service"
  else
    pass "live leg C: two workers (explicit and configured-default model, both mock/echo) ran on the one shared service with exact recorded sessions; a worker shell cannot claim the lead home"
  fi
else
  live_fail "workers did not both execute on the shared service: $(printf '%s ' "$LAB"/worker-*)"
fi
fi

# Leg D: an observer UI on the lead session replaces its environment; the owner
# restores routing and keeps its claim.
if leg D; then
CLAIM_A=$(record_field "$PRIMARY" "$LEAD_A" claimID)
termctrl start observer --cols 120 --rows 30 -- "${ISO[@]}" FM_V2_REGISTRY_NAMESPACE="$FM_V2_REGISTRY_NAMESPACE" "$SC" --session "$LEAD_A" >/dev/null \
  || live_fail "could not start the observer UI"
TERMS+=(observer)
sleep 6
run_in_session "$LEAD_A" "bash bin/fm-lock.sh; echo rc=\$? > $LAB/observer-lock" || true
if grep -q '^rc=0$' "$LAB/observer-lock" 2>/dev/null && [ "$(record_field "$PRIMARY" "$LEAD_A" claimID)" = "$CLAIM_A" ] \
  && [ "$(record_field "$PRIMARY" "$LEAD_A" ownerPID)" = "${OWNER_A:-x}" ]; then
  pass "live leg D: with an observer UI attached, the lead keeps its claim and its shell still holds the home lock"
else
  live_fail "observer leg: lock=$(cat "$LAB/observer-lock" 2>/dev/null) claim=$(record_field "$PRIMARY" "$LEAD_A" claimID) owner=$(record_field "$PRIMARY" "$LEAD_A" ownerPID)"
fi
termctrl stop observer >/dev/null 2>&1 || true
fi

# Leg G: queued wakes from two real workers, one while the lead is busy and one
# while it is idle. Each worker's real turn appends a status line to a task the
# lead supervises; the lead's watcher wakes it; the wake is admitted queued and
# handled exactly once through the real drain/ack (counted by successful
# canonical acknowledgements, not text).
if leg G && [ -n "${W1:-}" ] && [ -n "${W2:-}" ]; then
  printf 'kind=ship\n' > "$HOME_A/state/t2.meta"
  : > "$LAB/handled.log"
  api post "/api/session/$LEAD_A/prompt" "$(jq -nc --arg t "RUN: sleep 12; touch $LAB/busy-done" '{text: $t, delivery: "queue"}')" >/dev/null
  sleep 2
  run_in_session "$W1" "printf 'done: w1 finished\\n' >> $HOME_A/state/t1.status" || true
  acks() { grep -c '^acked ' "$LAB/handled.log" 2>/dev/null || echo 0; }
  one_ack() { [ "$(acks)" -ge 1 ]; }
  wait_until 120 one_ack || live_fail "the busy-lead wake was never handled"
  busy_done=no
  [ -e "$LAB/busy-done" ] && busy_done=yes
  first_ack_ns=$(awk '/^acked /{print $3; exit}' "$LAB/handled.log")
  done_ns=$(date -r "$LAB/busy-done" +%s%N 2>/dev/null || echo 0)
  sleep 3
  run_in_session "$W2" "printf 'done: w2 finished\\n' >> $HOME_A/state/t2.status" || true
  two_acks() { [ "$(acks)" -ge 2 ]; }
  wait_until 60 two_acks || live_fail "the idle-lead wake was never handled"
  sleep 4
  api get "/api/experimental/session/$LEAD_A/export" > "$LAB/transcript-$LEAD_A.json" 2>/dev/null || true
  wake_msgs=$(jq '[.data.messages[]? | select(.type == "user" and (.text | test("WATCHER FIRED")))] | length' "$LAB/transcript-$LEAD_A.json")
  if [ "$busy_done" = yes ] && [ "$(acks)" = 2 ] && [ "$wake_msgs" = 2 ] && [ -n "$first_ack_ns" ] && [ "$first_ack_ns" -ge "$done_ns" ]; then
    pass "live leg G: a wake raised while the lead was busy was queued and handled after its turn, an idle-lead wake was handled promptly; two wakes, two canonical acks, no duplicate execution"
  else
    live_fail "busy/idle wakes: busy-done=$busy_done acks=$(acks) wake-prompts=$wake_msgs first-ack=$first_ack_ns busy-turn-end=$done_ns handled=$(tr '\n' ';' < "$LAB/handled.log")"
  fi
elif leg G; then
  live_fail "leg G needs the two workers from leg C"
fi

# Leg E: service restart, then the same owner's /firstmate-rebind.
if leg E; then
(cd "$LAB" && isolated FM_LIVE_MOCK_KEY=mock "$SC" service restart >/dev/null 2>&1) || live_fail "isolated service restart failed"
NEW_SERVICE=$(jq -r '.pid' "$LAB/xdg/state/shuvcode/service.json")
if [ "$NEW_SERVICE" = "$SERVICE_PID" ] || ! live_pid "$NEW_SERVICE"; then
  live_fail "service restart did not produce a new live service incarnation"
else
  # Negative control: before the explicit rebind the stale registration
  # refuses the lead's shell commands with the rebind diagnostic.
  run_in_session "$LEAD_A" "touch $LAB/pre-rebind" || true
  pre_state=$(tool_state "$LEAD_A" "touch $LAB/pre-rebind")
  if [ ! -e "$LAB/pre-rebind" ] && printf '%s' "$pre_state" | jq -e '.status == "error" and (.error | test("rebind"))' >/dev/null; then
    pass "live leg E: after the service restart and before rebind the lead's command was refused with the rebind diagnostic"
  else
    live_fail "before rebind: marker=$([ -e "$LAB/pre-rebind" ] && echo present || echo absent) tool=$pre_state"
  fi
  # Type the command, wait until the real UI lists it, then submit; a
  # back-to-back Enter can race the command list.
  termctrl send lead-a text:/firstmate-rebind >/dev/null 2>&1 || true
  termctrl wait lead-a "Rebind Firstmate execution service" --timeout 15000 >/dev/null 2>&1 \
    || live_fail "the real UI never listed /firstmate-rebind"
  termctrl send lead-a enter >/dev/null 2>&1 || true
  rebound() { [ "$(record_field "$PRIMARY" "$LEAD_A" servicePID)" = "$NEW_SERVICE" ] && lead_active "$PRIMARY" "$HOME_A" "$LEAD_A"; }
  if wait_until 60 rebound; then
    run_in_session "$LEAD_A" "bash bin/fm-lock.sh; echo rc=\$? > $LAB/rebind-lock" || true
    if grep -q '^rc=0$' "$LAB/rebind-lock" 2>/dev/null; then
      pass "live leg E: the owner's /firstmate-rebind republished service $NEW_SERVICE as active with a live watcher, and its shell holds the lock"
    else
      live_fail "after rebind the lead shell could not hold its lock: $(cat "$LAB/rebind-lock" 2>/dev/null)"
    fi
  else
    termctrl show lead-a > "$LAB/lead-a-rebind-screen.txt" 2>&1 || true
    live_fail "the owner did not republish the new service after /firstmate-rebind: record=$(owner "$PRIMARY" read "$LEAD_A")"
  fi
  SERVICE_PID=$NEW_SERVICE
fi
fi

# Leg F: Herdr detach/attach with the real owner (bin/fm-herdr-lab.sh).
if ! leg F; then :
elif [ "${FM_OPENCODE_V2_HERDR_LIVE:-0}" = 1 ]; then
  PRIMARY_H="$LAB/primary-h"
  make_live_primary "$PRIMARY_H"
  HOME_H=$(make_home "$LAB/home-h")
  LEAD_H=$(create_session "$PRIMARY_H")
  EXEC_SES=$(create_session "$PRIMARY_H")
  owner_cmd=$(lead_command "$PRIMARY_H" "$HOME_H" "$LEAD_H" | while IFS= read -r a; do printf '%q ' "$a"; done)
  reg="${ISO[*]@Q} FM_V2_REGISTRY_NAMESPACE=$FM_V2_REGISTRY_NAMESPACE node $PRIMARY_H/bin/fm-opencode-v2-owner.mjs read $LEAD_H"
  api_cmd="cd $LAB && ${ISO[*]@Q} $SC api post /api/session/$EXEC_SES/prompt --data"
  # The sentinel records the exact live watcher; retirement requires that same
  # process gone, so a removed pid file cannot make the check vacuous.
  # shellcheck disable=SC2016 # $LAB below is the Herdr leg's own lab, expanded when the knob runs
  FM_V2_HERDR_OWNER_CMD="$owner_cmd" \
  FM_V2_HERDR_OWNER_PID_CMD="cat $HOME_H/state/.lock" \
  FM_V2_HERDR_SENTINEL_CMD="[ \"\$($reg | jq -r .lifecycle)\" = active ] && w=\$(cat $HOME_H/state/.watch.lock/pid) && kill -0 \"\$w\" && echo \"\$w\" > $LAB/herdr-watcher.pid" \
  FM_V2_HERDR_RETIRED_CMD="[ \"\$($reg | jq -r .lifecycle)\" = retired ] && w=\$(cat $LAB/herdr-watcher.pid) && [ -n \"\$w\" ] && ! kill -0 \"\$w\" 2>/dev/null" \
  FM_V2_HERDR_OWNER_EXIT_KEYS="ctrl+c ctrl+c" \
  FM_V2_HERDR_EXEC_CMD="$api_cmd \"\$(jq -nc --arg t \"RUN: while :; do date +%s%N > \$LAB/exec.beat; sleep 0.2; done\" '{text: \$t, delivery: \"queue\"}')\" >/dev/null; for i in \$(seq 1 100); do [ -s \$LAB/exec.beat ] && break; sleep 0.2; done; pgrep -n -f 'exec.beat; sleep 0.2'" \
  FM_V2_HERDR_OWNER_READY_TRIES=300 FM_V2_HERDR_RETIRE_TRIES=300 \
    bash "$ROOT/tests/fm-opencode-v2-herdr-detach-live.test.sh" > "$LAB/herdr-leg.log" 2>&1
  herdr_status=$?
  if [ "$herdr_status" -eq 0 ]; then
    pass "live leg F: Herdr detach/attach with the real owner ($(grep -c '^ok' "$LAB/herdr-leg.log") checks)"
  else
    live_fail "Herdr leg with the real owner failed: $(grep -E '^(not ok|note)' "$LAB/herdr-leg.log" | head -5) registry=$(owner "$PRIMARY_H" read "$LEAD_H") sidecar=$(cat "$HOME_H/state/.opencode-v2-owner.json" 2>/dev/null)"
  fi
else
  printf 'pending - live leg F (Herdr detach/attach with the real owner): set FM_OPENCODE_V2_HERDR_LIVE=1\n'
  [ "${FM_V2_ACCEPT_STRICT:-0}" != 1 ] || live_fail "strict: Herdr leg not requested"
fi

# Leg H: a worker mid-turn when the service restarts (review F5-B1). shuvcode's
# successor resumes the suspended turn, so the worker reconciliation helper
# (teardown, control interrupt, descendant preflight) must consult the
# successor at the frozen endpoint, never conclude "stopped" from the gone
# incarnation, and interrupt the exact session there.
if leg H; then
  WDIR_H="$LAB/worker-h"
  mkdir -p "$WDIR_H"
  git init -q "$WDIR_H"
  WDIR_H=$(cd -P "$WDIR_H" && pwd -P)
  worker_task worker-h
  termctrl start worker-h --cols 120 --rows 30 -- "${ISO[@]}" bash -c \
    "cd '$WDIR_H' && exec '$PRIMARY/bin/fm-opencode-v2-launch.sh' --model mock/echo --prompt 'RUN: while :; do date +%s%N > $LAB/h.beat; sleep 0.3; done' --session-record '$LAB/workers/worker-h.opencode-v2-session.json'" >/dev/null \
    || live_fail "could not start worker H"
  TERMS+=(worker-h)
  WDIR_H2="$LAB/worker-h2"
  mkdir -p "$WDIR_H2"
  git init -q "$WDIR_H2"
  WDIR_H2=$(cd -P "$WDIR_H2" && pwd -P)
  worker_task worker-h2
  termctrl start worker-h2 --cols 120 --rows 30 -- "${ISO[@]}" bash -c \
    "cd '$WDIR_H2' && exec '$PRIMARY/bin/fm-opencode-v2-launch.sh' --model mock/echo --prompt 'RUN: date +%s%N > $LAB/h2.started; sleep 600' --session-record '$LAB/workers/worker-h2.opencode-v2-session.json'" >/dev/null \
    || live_fail "could not start worker H2"
  TERMS+=(worker-h2)
  worker2_session() { (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-session.mjs" "$1" "$LAB/workers/worker-h2.opencode-v2-session.json" "$WDIR_H2" 2>"$LAB/h2.$1.err"); }
  h2_started() { [ -s "$LAB/h2.started" ] && [ -s "$LAB/workers/worker-h2.opencode-v2-session.json" ]; }
  wait_until 120 h2_started || live_fail "worker H2 never started its turn"
  worker_session() { (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-session.mjs" "$1" "$LAB/workers/worker-h.opencode-v2-session.json" "$WDIR_H" 2>"$LAB/h.$1.err"); }
  beating_since() { [ -s "$LAB/h.beat" ] && [ "$(cat "$LAB/h.beat")" -gt "$1" ]; }
  if ! wait_until 120 beating_since 0 || [ ! -s "$LAB/workers/worker-h.opencode-v2-session.json" ]; then
    live_fail "worker H never started its long turn"
  else
    h_status=$(worker_session status)
    if printf '%s' "$h_status" | jq -e '.executing == true' >/dev/null; then
      pass "live leg H: positive control: the mid-turn worker reports executing on its own service"
    else
      live_fail "positive control: mid-turn worker H not reported executing: $h_status $(cat "$LAB/h.status.err")"
    fi
    restart_ns=$(date +%s%N)
    (cd "$LAB" && isolated FM_LIVE_MOCK_KEY=mock "$SC" service restart >/dev/null 2>&1) || live_fail "leg H service restart failed"
    resumed() { [ -s "$LAB/h.resumed" ] && beating_since "$restart_ns"; }
    if ! wait_until 120 resumed; then
      live_fail "premise: the successor service did not resume worker H's suspended turn (resumed=$(cat "$LAB/h.resumed" 2>/dev/null) beat=$(cat "$LAB/h.beat" 2>/dev/null))"
    else
      pass "live leg H: premise: after the service restart the successor resumed worker H's suspended turn"
      h_status=$(worker_session status)
      if printf '%s' "$h_status" | jq -e '.executing == true' >/dev/null; then
        pass "live leg H: the resumed worker is reported executing after the restart"
      else
        live_fail "[F5-B1] the resumed worker was reported $h_status after the restart"
      fi
      if worker_session teardown >/dev/null; then
        live_fail "[F5-B1] teardown accepted the worker the successor is executing"
      else
        pass "live leg H: teardown refuses the resumed worker"
      fi
      h_int=$(worker_session interrupt)
      stopped_since() { local t; t=$(cat "$LAB/h.beat"); sleep 2; [ "$(cat "$LAB/h.beat")" = "$t" ]; }
      if wait_until 10 stopped_since; then
        pass "live leg H: interrupt cancelled the resumed turn on the successor ($h_int)"
        if h_td=$(worker_session teardown) && printf '%s' "$h_td" | jq -e '.executing == false' >/dev/null; then
          pass "live leg H: after the confirmed successor cancellation ordinary teardown reconciles the worker"
        else
          live_fail "after the confirmed cancellation ordinary teardown still refused: $h_td $(cat "$LAB/h.teardown.err")"
        fi
      else
        live_fail "[F5-B1] interrupt reported $h_int but the resumed turn kept running"
      fi
      # Worker H2: its resumed turn finished by itself on the successor. While
      # settlement is unproven ordinary teardown refuses; once the successor
      # passes its settlement bound, ordinary teardown reconciles it as settled.
      h2_resumed() { [ -s "$LAB/h2.resumed" ]; }
      h2_idle() { worker2_session status | jq -e '.observedExecuting == false' >/dev/null 2>&1; }
      if ! wait_until 120 h2_resumed || ! wait_until 60 h2_idle; then
        live_fail "premise: worker H2's turn was not resumed and finished on the successor (resumed=$(cat "$LAB/h2.resumed" 2>/dev/null) status=$(worker2_session status))"
      else
        pass "live leg H: premise: the successor resumed worker H2's turn, which then finished"
        if [ $(( $(date +%s%N) - restart_ns )) -lt 25000000000 ]; then
          if worker2_session teardown >/dev/null; then
            live_fail "[F7-M1] ordinary teardown accepted worker H2 before its successor settlement was provable"
          elif grep -qiE 'retry|--force' "$LAB/h2.teardown.err"; then
            pass "live leg H: before settlement is provable ordinary teardown refuses worker H2 naming a retry or --force"
          else
            live_fail "the unproven refusal for worker H2 named neither a retry nor --force: $(cat "$LAB/h2.teardown.err")"
          fi
        else
          live_fail "fixture: worker H2 reached idle too late to observe the unproven refusal"
        fi
        settle_by=$(( restart_ns / 1000000000 + 35 ))
        while [ "$(date +%s)" -lt "$settle_by" ]; do sleep 1; done
        settled_h2() { h2_td=$(worker2_session teardown) && printf '%s' "$h2_td" | jq -e '.executing == false and .cancellation == "settled"' >/dev/null; }
        if wait_until 20 settled_h2; then
          pass "live leg H: once settlement is provable ordinary teardown reconciles worker H2 as settled ($h2_td)"
        else
          live_fail "[F7-M1] ordinary teardown still refused the settled worker H2: ${h2_td:-} $(cat "$LAB/h2.teardown.err")"
        fi
      fi
    fi
  fi
fi

[ "$LIVE_FAILED" -eq 0 ] || { printf 'not ok - %s live qualification check(s) failed\n' "$LIVE_FAILED" >&2; exit 1; }
