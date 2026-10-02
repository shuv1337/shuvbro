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
isolated() {
  env -u OPENCODE_CONFIG_DIR -u OPENCODE_SESSION_ID -u OPENCODE -u OPENCODE_TERMINAL \
    -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    PATH="$NODE_DIR:$PATH" XDG_CONFIG_HOME="$LAB/xdg/config" XDG_STATE_HOME="$LAB/xdg/state" \
    XDG_DATA_HOME="$LAB/xdg/data" XDG_CACHE_HOME="$LAB/xdg/cache" "$@"
}

cleanup() {
  local status=$? reg_pid=
  if [ "$SERVICE_STARTED" = 1 ]; then
    reg_pid=$(jq -r '.pid // empty' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null)
    (cd "$LAB" && isolated "$SC" service stop >/dev/null 2>&1) || true
    if [ -n "$reg_pid" ] && kill -0 "$reg_pid" 2>/dev/null; then
      printf 'not ok - isolated service pid %s survived service stop\n' "$reg_pid" >&2
      status=1
    fi
  fi
  [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null
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
    const match = lastUser && /RUN: ([^\n]+)/.exec(text(lastUser.content));
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
node "$LAB/mock.mjs" "$MOCK_PORT" "$LAB/mock.log" >/dev/null 2>&1 &
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

# Prompt one RUN command into a session and wait for its execution to settle.
run_in_session() {  # <session-id> <command> <done-file>
  api post "/api/session/$1/prompt" "$(jq -nc --arg t "RUN: $2" '{text: $t, delivery: "queue"}')" >/dev/null \
    || { live_fail "prompt admission failed for $1"; return 1; }
  for _ in $(seq 1 100); do
    if [ "$(grep -c '"lastIsTool":true' "$LAB/mock.log" 2>/dev/null)" -ge "$3" ]; then
      sleep 0.5
      api get "/api/experimental/session/$1/export" > "$LAB/transcript-$1.json" || true
      return 0
    fi
    sleep 0.2
  done
  live_fail "session $1 did not complete its live tool turn"
  return 1
}

# --- phase 2: plugin inventory ----------------------------------------------
PRIMARY="$LAB/primary"
make_live_primary "$PRIMARY"
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
if [ -n "${FM_V2_TEST_LEAD_PLUGIN_ID:-}" ]; then
  count=$(printf '%s' "$inventory" | jq --arg id "$FM_V2_TEST_LEAD_PLUGIN_ID" '[.data[] | select(.id == $id and .state.status == "active")] | length')
  [ "$count" = 1 ] || live_fail "expected exactly one active V2 lead implementation $FM_V2_TEST_LEAD_PLUGIN_ID, found $count"
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
if [ ! -e "$LAB/marker-lead" ]; then pass "live phase 3: the exact-marked lead's protected command was blocked before execution"
else live_fail "live guard scope: the exact-marked lead's protected command executed"; fi

# --- phase 4: lead model-shell identity on the shared service ----------------
turns=$((turns + 1))
run_in_session "$LEAD" "printf '%s %s %s\\n' \"\$OPENCODE_SESSION_ID\" \"\$(ps -o ppid= -p \$\$ | tr -d ' ')\" \"\${FM_LIVE_FIRST_CLIENT:-none}\" > $LAB/lead-identity; bash bin/fm-lock.sh > $LAB/lead-lock 2>&1; echo \"rc=\$?\" >> $LAB/lead-lock" "$turns" || true
if read -r id_session id_parent id_env < "$LAB/lead-identity" 2>/dev/null; then
  # Host fact the credential-free suites model: with no client-pushed session
  # environment, a model shell inherits the environment of whichever client
  # started the shared service, so ambient FM_* there can never be authority.
  [ "$id_env" = first-client ] \
    || live_fail "host fact changed: an API-created session's shell no longer inherits the service starter's environment (got '$id_env')"
  [ "$id_session" = "$LEAD" ] || live_fail "lead shell OPENCODE_SESSION_ID was '$id_session', expected $LEAD"
  case "$(ps -o args= -p "$id_parent" 2>/dev/null)" in
    *serve*--service*) ;;
    *) live_fail "lead shell parent $id_parent is not the shared service" ;;
  esac
  grep -q '^rc=0$' "$LAB/lead-lock" && live_fail "an unregistered marked lead acquired the home lock: $(cat "$LAB/lead-lock")"
  pass "live phase 4: the lead shell carries its exact session id under the shared service and cannot lock unregistered"
else
  live_fail "lead identity probe did not run"
fi

# --- phase 5: pending integration -------------------------------------------
for item in \
  "registered lead lock and guard deny/allow on the real host:registration writer and launch helper" \
  "two homes on one service:registration writer" \
  "TUI owner arm, quiet attach and wake delivery:TUI entry and launch helper" \
  "observer client stays inert:TUI entry" \
  "Herdr detach keeps the owner, TUI exit retires supervision:TUI entry with bin/fm-herdr-lab.sh named lab"; do
  printf 'pending - live %s: integration pending (%s)\n' "${item%%:*}" "${item#*:}"
  [ "${FM_V2_ACCEPT_STRICT:-0}" != 1 ] || live_fail "strict: ${item%%:*} pending"
done

[ "$LIVE_FAILED" -eq 0 ] || { printf 'not ok - %s live qualification check(s) failed\n' "$LIVE_FAILED" >&2; exit 1; }
