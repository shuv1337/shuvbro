#!/usr/bin/env bash
# Live qualification: native OpenCode V2 lead watcher succession on a real,
# isolated shuvcode shared service with the TUI owner activated by
# bin/fm-opencode-v2-primary.sh.
#
# Opt-in with FM_OPENCODE_V2_SUCCESSION_LIVE=1. Token-free: a local deterministic
# OpenAI-compatible mock plays the lead. It answers `RUN: <cmd>` with one real
# shell tool call, answers every WATCHER FIRED prompt by draining the wake queue
# and running the exact printed acknowledgement, and ends every other turn with
# text.
#
# Isolation: relocated XDG roots verified with `debug paths` before any service
# command, a lab-registered `serve --service` on a free loopback port, a fresh
# token-only owner registry namespace (FM_V2_REGISTRY_NAMESPACE) retired with
# the owner's cleanup-test-namespace command, and named termctrl PTYs for the
# TUI. The exit trap stops the TUI, the lab service and the mock, and fails if
# any of them, a watcher, or an arm survives. Watcher cadence is shortened
# (FM_POLL=2, FM_SIGNAL_GRACE=1) in the lab environment only.
#
# The primary is a fresh non-linked `git init` checkout carrying this tree's
# bin/, AGENTS.md, supervision protocols and .opencode/plugins.
#
# Cases:
#   - the native TUI entry completes setup (no plugin setup failure)
#   - session start in the lead acquires the home lock for the TUI owner
#   - first arm emits no turn-end-guard prompt and delivers the first wake
#   - steady succession: one prompt, one watcher, fresh beacon, empty queue
#   - watcher TERM/KILL and arm TERM recover and the next wake arrives once
#   - an arm SIGKILL that orphans its watcher does not strand the next wake
#   - subdirectory, unrelated and child root sessions never take over
#   - a server location reload keeps the TUI-owned watcher and delivery
#   - a TUI plugin hot reload keeps supervision under the same claim
#   - TUI exit retires the claim; relaunch nudges and re-arms after session start
#   - the documented /firstmate-rebind owner command is reachable
#   - a lead activated against a private `serve --stdio` server either owns
#     the home or is refused at activation, and never starts a background service
# Evidence is retained under the lab directory on failure.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_V2_SUCCESSION_LIVE shuvcode jq node git termctrl

[ -d "$ROOT/.opencode/plugins/node_modules/effect" ] \
  || fail "the native plugin runtime is not installed; run npm ci --prefix .opencode/plugins"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-v2-succ-live.XXXXXX")
LAB=$(cd -P "$LAB" && pwd -P)
PRIMARY="$LAB/primary"
NS="succ-live-$$-$RANDOM"
TAG="fmv2succ$$"
TUI="$TAG-lead"
OBS="$TAG-observer"
MOCK_PID=
HOLDER_PID=
LIVE_FAILED=0
NODE_DIR=$(dirname "$(node -p process.execPath)")

isolated() {
  env -u OPENCODE_CONFIG_DIR -u OPENCODE_SESSION_ID -u OPENCODE -u OPENCODE_TERMINAL \
    -u OPENCODE_PASSWORD -u OPENCODE_SERVER_PASSWORD -u FM_V2_ACTIVATION \
    -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    PATH="$NODE_DIR:$PATH" XDG_CONFIG_HOME="$LAB/xdg/config" XDG_STATE_HOME="$LAB/xdg/state" \
    XDG_DATA_HOME="$LAB/xdg/data" XDG_CACHE_HOME="$LAB/xdg/cache" FM_V2_REGISTRY_NAMESPACE="$NS" \
    FM_POLL=2 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 MOCK_API_KEY=mock "$@"
}

# Every process whose environment carries this lab's XDG state root.
lab_procs() {
  local p
  for p in $(pgrep -f "shuvcode|fm-watch|sleep" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_STATE_HOME=$LAB/xdg/state" && printf '%s\n' "$p"
  done
}
primary_procs() { pgrep -f "$PRIMARY/bin/fm-watch" || true; }

cleanup() {
  local status=$? p left
  termctrl stop "$OBS" >/dev/null 2>&1
  termctrl stop "$TUI" >/dev/null 2>&1
  [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null
  if [ -f "$LAB/xdg/state/shuvcode/service.json" ]; then
    (cd "$LAB" && isolated "$SC" service stop >/dev/null 2>&1) || true
  fi
  [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null
  sleep 2
  left="$(lab_procs) $(primary_procs)"
  if [ -n "${left// /}" ]; then
    printf 'not ok - lab processes survived cleanup: %s\n' "$left" >&2
    for p in $left; do kill "$p" 2>/dev/null; done
    status=1
  fi
  if ! (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-owner.mjs" cleanup-test-namespace >/dev/null 2>&1); then
    printf 'not ok - test registry namespace %s could not be cleaned\n' "$NS" >&2
    status=1
  fi
  termctrl prune >/dev/null 2>&1
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

SC=$(resolve_binary)
mkdir -p "$LAB/xdg/config/shuvcode" "$LAB/xdg/state" "$LAB/xdg/data" "$LAB/xdg/cache"
paths=$(cd "$LAB" && isolated "$SC" debug paths 2>/dev/null)
for kind in config state data; do
  value=$(printf '%s\n' "$paths" | awk -v k="$kind" '$1 == k { print $2 }')
  case "$value" in
    "$LAB"/*) ;;
    *) fail "isolation refused: shuvcode $kind path '$value' is outside the lab; no service command was run" ;;
  esac
done

# --- disposable non-linked primary --------------------------------------------
git init -q -b main "$PRIMARY"
git -C "$PRIMARY" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
cp -R "$ROOT/bin" "$PRIMARY/bin"
cp "$ROOT/AGENTS.md" "$PRIMARY/AGENTS.md"
mkdir -p "$PRIMARY/.opencode/plugins" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/data" "$PRIMARY/docs/sub"
cp -R "$ROOT/docs/supervision-protocols" "$PRIMARY/docs/supervision-protocols"
tar -C "$ROOT/.opencode/plugins" --exclude=./node_modules -cf - . | tar -C "$PRIMARY/.opencode/plugins" -xf -
ln -s "$ROOT/.opencode/plugins/node_modules" "$PRIMARY/.opencode/plugins/node_modules"
[ "$(git -C "$PRIMARY" rev-parse --git-dir)" = "$(git -C "$PRIMARY" rev-parse --git-common-dir)" ] \
  || fail "fixture: the disposable primary is a linked worktree"

# --- scripted lead ------------------------------------------------------------
cat > "$LAB/handle-wake.sh" <<'EOF'
#!/usr/bin/env bash
set -u
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
n=$(( $(cat "$LAB/handle.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$LAB/handle.count"
bin/fm-wake-drain.sh > "$LAB/drain-$n.out" 2> "$LAB/drain-$n.err"
cmd=$(grep '^WAKE_ACK_REQUIRED:' "$LAB/drain-$n.err" | tail -1 \
  | grep -o 'bin/fm-wake-drain.sh --ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*')
[ -z "$cmd" ] || bash $cmd > "$LAB/ack-$n.out" 2>&1
echo handled
EOF
chmod +x "$LAB/handle-wake.sh"
cat > "$LAB/mock.mjs" <<'EOF'
import http from "node:http";
import { appendFileSync } from "node:fs";
const [port, log, handle] = process.argv.slice(2);
const text = (c) => (typeof c === "string" ? c : (c || []).map((p) => p.text || "").join(""));
http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    if (!req.url.includes("chat/completions")) { res.writeHead(404); res.end(); return; }
    let parsed = {};
    try { parsed = JSON.parse(body); } catch {}
    const messages = parsed.messages || [];
    const users = messages.filter((m) => m.role === "user");
    const last = users.length ? text(users[users.length - 1].content) : "";
    const lastIsTool = messages.length > 0 && messages[messages.length - 1].role === "tool";
    const tools = (parsed.tools || []).map((t) => t.function?.name);
    let cmd = null;
    if (!lastIsTool && tools.includes("shell")) {
      if (/FIRSTMATE_OP: v1 watcher:/.test(last)) cmd = `bash ${handle}`;
      else { const m = /RUN: ([^\n]+)/.exec(last); if (m) cmd = m[1]; }
    }
    appendFileSync(log, JSON.stringify({ lastIsTool, cmd }) + "\n");
    res.writeHead(200, { "content-type": "text/event-stream" });
    const send = (o) => res.write(`data: ${JSON.stringify(o)}\n\n`);
    const base = { id: "mock", object: "chat.completion.chunk", created: 1, model: "echo" };
    if (cmd) {
      send({ ...base, choices: [{ index: 0, delta: { role: "assistant", tool_calls: [{ index: 0, id: `call_${Date.now()}`, type: "function", function: { name: "shell", arguments: JSON.stringify({ command: cmd, description: "lab" }) } }] }, finish_reason: null }] });
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
MOCK_PORT=$(free_port)
node "$LAB/mock.mjs" "$MOCK_PORT" "$LAB/mock.log" "$LAB/handle-wake.sh" >/dev/null 2>&1 &
MOCK_PID=$!
jq -n --arg url "http://127.0.0.1:$MOCK_PORT/v1" '{
  providers: { mock: { name: "Mock", env: ["MOCK_API_KEY"], package: "@opencode/ai/providers/openai-compatible",
    settings: { baseURL: $url, apiKey: "mock" }, models: { echo: { name: "Echo" } } } },
  model: "mock/echo" }' > "$LAB/xdg/config/shuvcode/opencode.json"

# --- lab shared service -------------------------------------------------------
(cd "$LAB" && isolated "$SC" service set port "$(free_port)" >/dev/null) || fail "could not configure the lab service port"
(cd "$LAB" && isolated "$SC" service start >/dev/null 2>&1) || fail "lab service did not start"
SERVICE_PID=$(jq -r '.pid' "$LAB/xdg/state/shuvcode/service.json")
tr '\0' '\n' < "/proc/$SERVICE_PID/environ" 2>/dev/null | grep -qx "XDG_STATE_HOME=$LAB/xdg/state" \
  || fail "registered service $SERVICE_PID is not the lab's own service"

MODE=shared URL='' PASS=''
api() {  # <method> <path> [--data json]
  if [ "$MODE" = private ]; then
    (cd "$LAB" && isolated OPENCODE_PASSWORD="$PASS" "$SC" api --server "$URL" "$@" 2>>"$LAB/api.err")
  else
    (cd "$LAB" && isolated "$SC" api "$@" 2>>"$LAB/api.err")
  fi
}
create_session() {  # <directory> [parent]
  api post /api/session --data "$(jq -nc --arg d "$1" --arg p "${2:-}" '{title: "lab", location: {directory: $d},
     model: {providerID: "mock", id: "echo"}, permissions: [{action: "shell", resource: "*", effect: "allow"}]}
     + (if $p == "" then {} else {parentID: $p} end)')" | jq -r '.data.id'
}
prompt() { api post "/api/session/$1/prompt" --data "$(jq -nc --arg t "$2" '{text: $t, delivery: "queue"}')" >/dev/null; }
texts() { api get "/api/experimental/session/$1/export" | jq -r '.. | objects | select(.text? != null) | .text'; }
count_in() { local n; n=$(texts "$1" | grep -c "$2") || true; printf '%s' "${n:-0}"; }
watchers() { pgrep -f "^bash $PRIMARY/bin/fm-watch.sh" | grep -c . || true; }
arms() { pgrep -f "$PRIMARY/bin/fm-watch-arm.sh" | grep -c . || true; }
watch_pid() { cat "$PRIMARY/state/.watch.lock/pid" 2>/dev/null || echo none; }
beacon_age() { local m; m=$(stat -c %Y "$PRIMARY/state/.last-watcher-beat" 2>/dev/null) || { echo 9999; return; }; echo $(( $(date +%s) - m )); }
handled() { cat "$LAB/handle.count" 2>/dev/null || echo 0; }
wait_handled() { local _; for _ in $(seq 1 "$2"); do [ "$(handled)" -gt "$1" ] && return 0; sleep 0.25; done; return 1; }
lifecycle() { (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-owner.mjs" read "$LEAD" 2>/dev/null) | jq -r '.lifecycle // "none"'; }
owner_pid() { (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-owner.mjs" read "$LEAD" 2>/dev/null) | jq -r '.ownerPID // "none"'; }
fired() { count_in "$LEAD" 'WATCHER FIRED'; }
blind() { count_in "$LEAD" 'turn-end-guard: TURN WOULD END BLIND'; }

cat > "$LAB/launch.sh" <<EOF
#!/bin/bash
# Activate the exact native lead through the production launcher.
unset OPENCODE_CONFIG_DIR OPENCODE_SESSION_ID OPENCODE OPENCODE_TERMINAL OPENCODE_PASSWORD OPENCODE_SERVER_PASSWORD FM_V2_ACTIVATION FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
export PATH="$NODE_DIR:\$PATH" XDG_CONFIG_HOME="$LAB/xdg/config" XDG_STATE_HOME="$LAB/xdg/state" XDG_DATA_HOME="$LAB/xdg/data" XDG_CACHE_HOME="$LAB/xdg/cache"
export FM_V2_REGISTRY_NAMESPACE="$NS" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 MOCK_API_KEY=mock TERM=xterm-256color
if [ -f "$LAB/private.url" ]; then
  export OPENCODE_PASSWORD="\$(cat "$LAB/private.pass")"
  exec "$PRIMARY/bin/fm-opencode-v2-primary.sh" --session "\$(cat "$LAB/lead.id")" --native-binary "$SC" --server "\$(cat "$LAB/private.url")"
fi
exec "$PRIMARY/bin/fm-opencode-v2-primary.sh" --session "\$(cat "$LAB/lead.id")" --native-binary "$SC"
EOF
chmod +x "$LAB/launch.sh"
start_tui() {
  termctrl stop "$TUI" >/dev/null 2>&1
  termctrl prune >/dev/null 2>&1
  termctrl start --cols 140 --rows 40 --cwd "$PRIMARY" "$TUI" -- bash "$LAB/launch.sh" >/dev/null 2>&1
  for _ in $(seq 1 60); do [ "$(lifecycle)" = claimed ] || [ "$(lifecycle)" = active ] && return 0; sleep 0.25; done
  return 1
}
session_start() {  # run canonical session start in the lead; wait for the TUI lock
  local tui
  prompt "$LEAD" "RUN: bin/fm-session-start.sh > $LAB/session-start.out 2>&1"
  tui=$(owner_pid)
  for _ in $(seq 1 120); do [ "$(cat "$PRIMARY/state/.lock" 2>/dev/null)" = "$tui" ] && return 0; sleep 0.25; done
  return 1
}
one_wake() {  # <label>: inject one status change; print "<ok> <prompts> <guard> <watchers> <beacon> <rows>"
  local h w g rows ok=0
  h=$(handled); w=$(fired); g=$(blind)
  printf 'done: %s\n' "$1" >> "$PRIMARY/state/lab.status"
  wait_handled "$h" "${2:-120}" && ok=1
  sleep 3
  rows=$(grep -c . "$PRIMARY/state/.wake-queue" 2>/dev/null) || true
  printf '%s %s %s %s %s %s\n' "$ok" "$(( $(fired) - w ))" "$(( $(blind) - g ))" "$(watchers)" "$(beacon_age)" "${rows:-0}"
}
wake_ok() {  # <label> [polls]
  local out
  out=$(one_wake "$@")
  printf '%s: %s\n' "$1" "$out" >> "$LAB/cycles.log"
  local ok prompts guard live beacon rows
  read -r ok prompts guard live beacon rows <<< "$out"
  [ "$ok" = 1 ] && [ "$prompts" = 1 ] && [ "$guard" = 0 ] && [ "$live" = 1 ] && [ "$beacon" -le 5 ] && [ "$rows" = 0 ]
}

# --- activation, session start, first arm ---------------------------------------
LEAD=$(create_session "$PRIMARY")
[ -n "$LEAD" ] && [ "$LEAD" != null ] || fail "could not create the lead session"
printf '%s\n' "$LEAD" > "$LAB/lead.id"
start_tui || fail "the native lead TUI never published its exact claim"
TUI_PID=$(owner_pid)
sleep 2
if grep -q 'plugin operation failed.*plugin=firstmate.native.v2' "$LAB"/xdg/data/shuvcode/log/*.log 2>/dev/null; then
  live_fail "native TUI entry setup failed: $(grep -h -o 'error="[^"]*" plugin=firstmate.native.v2' "$LAB"/xdg/data/shuvcode/log/*.log | sort -u | tr '\n' ' ')"
else
  pass "native TUI entry completed setup"
fi
session_start || fail "session start in the lead did not take the home lock for the TUI owner $TUI_PID"
pass "session start in the activated lead holds the home lock for the TUI owner"
sleep 2
g0=$(blind); h0=$(handled)
prompt "$LEAD" "RUN: printf 'kind=scout\\n' > state/lab.meta; printf 'working: started\\n' > state/lab.status"
wait_handled "$h0" 120 || live_fail "the first arm never delivered the new task's status wake"
sleep 3
if [ "$(blind)" = "$g0" ]; then pass "first arm emits no competing turn-end-guard prompt"
else live_fail "first arm raced the turn-end guard: $(( $(blind) - g0 )) TURN WOULD END BLIND prompt(s)"; fi

# --- steady succession ------------------------------------------------------------
steady_ok=1
for c in $(seq 1 "${FM_V2_SUCC_CYCLES:-10}"); do
  wake_ok "cycle $c" || { live_fail "steady cycle $c: $(tail -1 "$LAB/cycles.log")"; steady_ok=0; }
done
[ "$steady_ok" = 1 ] && pass "steady succession: ${FM_V2_SUCC_CYCLES:-10} wakes each gave one prompt, one watcher, a fresh beacon and an empty queue"

# --- kills mid-idle ---------------------------------------------------------------
for pair in watcher:TERM watcher:KILL arm:TERM; do
  what=${pair%%:*} sig=${pair#*:}
  if [ "$what" = watcher ]; then victim=$(watch_pid); else victim=$(pgrep -f "$PRIMARY/bin/fm-watch-arm.sh" | head -1); fi
  kill -"$sig" "$victim" 2>/dev/null
  sleep 8
  if [ "$(watchers)" = 1 ] && [ "$(arms)" = 1 ] && [ "$(beacon_age)" -le 5 ] && wake_ok "after $what $sig"; then
    pass "the $what SIG$sig mid-idle recovers and the next wake arrives once"
  else
    live_fail "after $what SIG$sig: watchers=$(watchers) arms=$(arms) $(tail -1 "$LAB/cycles.log")"
  fi
done
victim=$(pgrep -f "$PRIMARY/bin/fm-watch-arm.sh" | head -1)
kill -KILL "$victim" 2>/dev/null
sleep 5
out=$(one_wake "after arm KILL" 80)
printf 'after arm KILL: %s\n' "$out" >> "$LAB/cycles.log"
if [ "${out%% *}" = 1 ]; then
  pass "an arm SIGKILL that orphans its watcher does not strand the next wake"
else
  live_fail "after an arm SIGKILL the orphaned watcher's wake stayed undelivered for 20s (queue rows=$(echo "$out" | awk '{print $6}'))"
  wake_ok "flush after arm KILL" || true
fi

# --- other root and child sessions --------------------------------------------------
before=$(watch_pid)
SUB=$(create_session "$PRIMARY/docs/sub")
UNRELATED=$(create_session "$PRIMARY")
CHILD=$(create_session "$PRIMARY" "$LEAD")
for s in "$SUB" "$UNRELATED" "$CHILD"; do prompt "$s" "unrelated work"; done
sleep 10
others=0
for s in "$SUB" "$UNRELATED" "$CHILD"; do others=$(( others + $(count_in "$s" 'WATCHER FIRED') + $(count_in "$s" 'TURN WOULD END BLIND') )); done
if [ "$(watch_pid)" = "$before" ] && [ "$others" = 0 ] && wake_ok "with other sessions"; then
  sleep 1
  others=0
  for s in "$SUB" "$UNRELATED" "$CHILD"; do others=$(( others + $(count_in "$s" 'WATCHER FIRED') )); done
  if [ "$others" = 0 ]; then pass "subdirectory, unrelated and child sessions neither take over the watcher nor receive wakes"
  else live_fail "another session received $others watcher prompt(s)"; fi
else
  live_fail "another session disturbed supervision: watcher $before -> $(watch_pid), prompts to others=$others, $(tail -1 "$LAB/cycles.log")"
fi

# --- server location reload ---------------------------------------------------------
api post /api/location/reload --data '{}' >/dev/null || live_fail "location reload request failed"
sleep 6
if [ "$(watchers)" = 1 ] && [ "$(beacon_age)" -le 5 ] && wake_ok "after location reload"; then
  pass "a server location reload keeps TUI-owned supervision and delivery without a lead turn"
else
  live_fail "after location reload: watchers=$(watchers) beacon=$(beacon_age)s $(tail -1 "$LAB/cycles.log")"
fi

# --- TUI plugin hot reload ----------------------------------------------------------
# Editing the TUI entry makes the native TUI dispose and set the plugin up again
# in the same process; the immutable claim must carry supervision across it.
setups0=$(grep -c 'firstmate.native.v2' "$LAB"/xdg/data/shuvcode/log/*.log 2>/dev/null) || true
printf '\n// lab hot-reload touch\n' >> "$PRIMARY/.opencode/plugins/fm-native-v2/tui.js"
sleep 8
reload_log=$(grep -h 'firstmate.native.v2' "$LAB"/xdg/data/shuvcode/log/*.log 2>/dev/null | tail -n +"$(( ${setups0:-0} + 1 ))" | grep -o 'error="[^"]*"' | sort -u | tr '\n' ' ')
if [ "$(watchers)" = 1 ] && [ -z "$reload_log" ] && wake_ok "after TUI hot reload"; then
  pass "a TUI plugin hot reload keeps supervision under the same claim and delivers the next wake"
else
  live_fail "after TUI plugin hot reload: watchers=$(watchers) setup errors: ${reload_log:-none} $(tail -1 "$LAB/cycles.log")"
  [ "$(handled)" -gt 0 ] && wake_ok "flush after hot reload" >/dev/null 2>&1 || true
fi

# --- owner command reachability -------------------------------------------------------
termctrl send "$TUI" ctrl-p >/dev/null 2>&1
sleep 1
termctrl send "$TUI" text:Rebind >/dev/null 2>&1
sleep 1.5
if termctrl show "$TUI" 2>/dev/null | grep -q 'Rebind Firstmate execution service'; then
  pass "the documented rebind owner command is reachable in the TUI"
else
  live_fail "the documented /firstmate-rebind owner command is not registered in the TUI (palette search 'Rebind' found nothing)"
fi
termctrl send "$TUI" escape >/dev/null 2>&1

# --- TUI exit and relaunch ------------------------------------------------------------
termctrl stop "$TUI" >/dev/null 2>&1
sleep 3
if [ "$(lifecycle)" = retired ] && [ "$(watchers)" = 0 ] && [ "$(arms)" = 0 ] && kill -0 "$SERVICE_PID" 2>/dev/null; then
  pass "TUI exit retires the claim and supervision while the shared service keeps running"
else
  live_fail "after TUI exit: lifecycle=$(lifecycle) watchers=$(watchers) arms=$(arms)"
fi
printf 'done: while the TUI was down\n' >> "$PRIMARY/state/lab.status"
nudges=$(count_in "$LEAD" 'session-start: Run')
start_tui || live_fail "relaunched TUI did not publish its claim"
sleep 4
[ "$(count_in "$LEAD" 'session-start: Run')" -gt "$nudges" ] || live_fail "relaunched TUI did not nudge session start without a lead turn"
h=$(handled)
if session_start && wait_handled "$h" 60; then
  sleep 3
  if wake_ok "after relaunch"; then pass "a relaunched TUI re-arms after session start and delivers the held and later wakes"
  else live_fail "after relaunch: $(tail -1 "$LAB/cycles.log")"; fi
else
  live_fail "after relaunch the held wake was not delivered (lock=$(cat "$PRIMARY/state/.lock" 2>/dev/null) watchers=$(watchers))"
fi

# --- private serve --stdio lead -----------------------------------------------------------
if [ "${FM_V2_SUCC_PRIVATE:-1}" = 1 ]; then
  termctrl stop "$TUI" >/dev/null 2>&1
  (cd "$LAB" && isolated "$SC" service stop >/dev/null 2>&1) || true
  sleep 2
  PASS=$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')
  printf '%s\n' "$PASS" > "$LAB/private.pass"
  mkfifo "$LAB/lease"
  (cd "$PRIMARY" && isolated OPENCODE_PASSWORD="$PASS" OPENCODE_SERVER_PASSWORD="$PASS" \
    "$SC" serve --stdio --hostname 127.0.0.1 --port 0 < "$LAB/lease" > "$LAB/ready" 2> "$LAB/private.err") &
  bash -c 'exec 3>"$1"; exec sleep 3600' _ "$LAB/lease" </dev/null >/dev/null 2>&1 &
  HOLDER_PID=$!
  for _ in $(seq 1 100); do URL=$(jq -er '.url' "$LAB/ready" 2>/dev/null) && break; sleep 0.1; done
  printf '%s\n' "$URL" > "$LAB/private.url"
  MODE=private
  before_service=$(jq -r '.pid // empty' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null)
  if start_tui; then
    session_start || true
    sleep 3
    after_service=$(jq -r '.pid // empty' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null)
    spawned=no
    if [ -n "$after_service" ] && [ "$after_service" != "$before_service" ] && kill -0 "$after_service" 2>/dev/null; then spawned=yes; fi
    if [ "$(cat "$PRIMARY/state/.lock" 2>/dev/null)" = "$(owner_pid)" ] && [ "$spawned" = no ]; then
      pass "a lead activated against a private server owns its home"
    else
      live_fail "a lead activated against a private server was accepted but cannot take its home lock (lock=$(cat "$PRIMARY/state/.lock" 2>/dev/null) owner=$(owner_pid)); helper side effect started a background service: $spawned"
    fi
  else
    pass "a lead against a private server is refused at activation"
  fi
fi

[ "$LIVE_FAILED" -eq 0 ] || exit 1
