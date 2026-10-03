#!/usr/bin/env bash
# Live qualification: native OpenCode V2 lead watcher succession on a real,
# isolated shuvcode shared service with the TUI owner activated by
# bin/fm-opencode-v2-primary.sh.
#
# Opt-in with FM_OPENCODE_V2_SUCCESSION_LIVE=1. Token-free: a local deterministic
# OpenAI-compatible mock plays the lead. It answers `RUN: <cmd>` with one real
# shell tool call, and answers every WATCHER FIRED prompt with the canonical
# handling step: the real drain plus its exact generation-bound acknowledgement,
# recorded in handled.log only when that acknowledgement succeeds.
#
# Isolation comes from tests/fm-opencode-v2-acceptance-lib.sh: a fresh
# token-only FM_V2_REGISTRY_NAMESPACE (never default), ambient
# OPENCODE_SESSION_ID/FM_V2_ACTIVATION stripped, fixture processes tracked by
# pid plus /proc start token, and cleanup-test-namespace teardown that fails the
# run when refused. Relocated XDG roots are verified with `debug paths` before
# any service command; the lab-registered `serve --service` listens on a free
# loopback port; TUIs run in named termctrl PTYs under a lab-private runtime
# directory. Watcher cadence is shortened (FM_POLL=2, FM_SIGNAL_GRACE=1) in the
# lab environment only.
#
# Evidence model: a handled wake is a successful canonical acknowledgement, and
# a delivered wake is a distinct native user message whose exact `msg_` ID is a
# journaled admission. Presentation text is never counted. Transitions are
# awaited by bounded readiness polls; fixed windows only assert absence.
#
# Cases (the bracketed tag names the production defect a red case depends on):
#   - the native TUI entry completes setup                         [D6]
#   - session start makes native .lock == the activated TUI process PID
#   - first arm: one watcher, no turn-end-guard prompt, first wake handled once
#   - steady succession: each wake one admitted message ID and one canonical ack
#   - watcher TERM/KILL and arm TERM recover: an idle watcher death presents
#     exactly one no-row resurface; next wake handled once           [F4-B1]
#   - arm SIGKILL with a surviving watcher does not strand the next wake [D5, D8]
#   - subdirectory, unrelated and child sessions never own or receive wakes
#   - server package reload: TUI process, claim and watcher keep their lifetimes
#   - TUI plugin reload: same TUI process and claim, setup succeeds, wake handled [D6]
#   - the documented rebind owner command is reachable              [D6]
#   - TUI exit retires; relaunch nudges, re-owns .lock and handles the held wake
#   - a lead activated against a private `serve --stdio` server owns its home or
#     is refused at activation, and never starts a background service [D7]
# Evidence is retained under the lab directory on failure.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"
fm_live_gate opt-in FM_OPENCODE_V2_SUCCESSION_LIVE shuvcode jq node git termctrl

v2_native_ready || fail "native V2 package absent from $V2_CODE_ROOT"
[ -d "$V2_CODE_ROOT/.opencode/plugins/node_modules/effect" ] \
  || fail "the native plugin runtime is not installed; run npm ci --prefix .opencode/plugins"
v2_assert_test_namespace
NS=$FM_V2_REGISTRY_NAMESPACE

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-v2-succ-live.XXXXXX")
LAB=$(cd -P "$LAB" && pwd -P)
PRIMARY="$LAB/primary"
TUI=lead
LIVE_FAILED=0
SERVICE_STARTED=0
NODE_DIR=$(dirname "$(node -p process.execPath)")
export TERMCTRL_RUNTIME_DIR="$LAB/tc"
mkdir -p "$TERMCTRL_RUNTIME_DIR"

isolated() {
  env -u OPENCODE_CONFIG_DIR -u OPENCODE_SESSION_ID -u OPENCODE -u OPENCODE_TERMINAL \
    -u OPENCODE_PASSWORD -u OPENCODE_SERVER_PASSWORD -u FM_V2_ACTIVATION \
    -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV \
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

cleanup() {
  local status=$? left reg
  termctrl stop "$TUI" >/dev/null 2>&1
  if [ "$SERVICE_STARTED" = 1 ]; then
    reg=$(jq -r '.pid // empty' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null)
    (cd "$LAB" && isolated "$SC" service stop >/dev/null 2>&1) || true
    if [ -n "$reg" ] && kill -0 "$reg" 2>/dev/null; then
      printf 'not ok - lab service pid %s survived service stop\n' "$reg" >&2
      status=1
    fi
  fi
  # The lease holder, mock and private server are tracked by identity and
  # retired by the shared teardown, which also cleans the token namespace.
  v2_teardown
  [ "$V2_TEARDOWN_FAILED" = 0 ] || status=1
  left=$(lab_procs | tr '\n' ' ')
  if [ -n "${left// /}" ]; then
    printf 'not ok - lab processes survived cleanup: %s\n' "$left" >&2
    status=1
  fi
  if [ -n "$(pgrep -f "$PRIMARY/bin/fm-watch" 2>/dev/null)" ]; then
    printf 'not ok - watcher or arm processes for the lab primary survived cleanup\n' >&2
    status=1
  fi
  if [ "$status" -eq 0 ] && [ "$LIVE_FAILED" -eq 0 ]; then
    rm -rf "$LAB"
  else
    printf 'note: live evidence retained at %s\n' "$LAB" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  fm_test_cleanup 2>/dev/null
  exit "$status"
}
trap cleanup EXIT

live_fail() { printf 'not ok - %s\n' "$1" >&2; LIVE_FAILED=$((LIVE_FAILED + 1)); }
wait_until() {  # <tries of 0.25s> <command...>
  local n=$1
  shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.25; n=$((n - 1)); done
  return 1
}

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
cp -R "$V2_CODE_ROOT/bin" "$PRIMARY/bin"
cp "$V2_CODE_ROOT/AGENTS.md" "$PRIMARY/AGENTS.md"
mkdir -p "$PRIMARY/.opencode/plugins" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/data" "$PRIMARY/docs/sub"
cp -R "$V2_CODE_ROOT/docs/supervision-protocols" "$PRIMARY/docs/supervision-protocols"
tar -C "$V2_CODE_ROOT/.opencode/plugins" --exclude=./node_modules -cf - . | tar -C "$PRIMARY/.opencode/plugins" -xf -
ln -s "$V2_CODE_ROOT/.opencode/plugins/node_modules" "$PRIMARY/.opencode/plugins/node_modules"
[ "$(git -C "$PRIMARY" rev-parse --git-dir)" = "$(git -C "$PRIMARY" rev-parse --git-common-dir)" ] \
  || fail "fixture: the disposable primary is a linked worktree"

# --- scripted lead ------------------------------------------------------------
# A wake is "handled" only when the canonical acknowledgement exits 0; the
# record carries the acknowledged sequence and recovery generation.
cat > "$LAB/handle-wake.sh" <<'EOF'
#!/usr/bin/env bash
set -u
LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
err=$(bin/fm-wake-drain.sh 2>&1 >/dev/null)
seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' | tail -1)
gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' | tail -1)
if [ -n "$seq" ] && [ -n "$gen" ] && bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1; then
  printf 'acked %s %s %s\n' "$seq" "$gen" "$(date +%s%N)" >> "$LAB/handled.log"
  echo handled
else
  printf 'ack-failed %s %s %s\n' "${seq:-none}" "${gen:-none}" "$(date +%s%N)" >> "$LAB/handled.log"
  echo ack-failed
fi
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
      if (/^\u2063?FIRSTMATE_OP: v1 watcher:.*WATCHER FIRED/.test(last)) cmd = `bash ${handle}`;
      else { const m = /^RUN: ([^\n]+)/.exec(last); if (m) cmd = m[1]; }
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
v2_track $!
jq -n --arg url "http://127.0.0.1:$MOCK_PORT/v1" '{
  providers: { mock: { name: "Mock", env: ["MOCK_API_KEY"], package: "@opencode/ai/providers/openai-compatible",
    settings: { baseURL: $url, apiKey: "mock" }, models: { echo: { name: "Echo" } } } },
  model: "mock/echo" }' > "$LAB/xdg/config/shuvcode/opencode.json"

# --- lab shared service -------------------------------------------------------
(cd "$LAB" && isolated "$SC" service set port "$(free_port)" >/dev/null) || fail "could not configure the lab service port"
(cd "$LAB" && isolated "$SC" service start >/dev/null 2>&1) || fail "lab service did not start"
SERVICE_STARTED=1
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
# Native user messages of one session: "<id>\t<first line of text>".
user_messages() {
  api get "/api/experimental/session/$1/export" \
    | jq -r '[.data.messages[]? | select(.type == "user")] | .[] | [.id, ((.text // "") | gsub("\u2063"; "") | split("\n")[0])] | @tsv'
}
# Exact IDs of the watcher wake messages delivered to a session.
wake_ids() { user_messages "$1" | awk -F'\t' '$2 ~ /^FIRSTMATE_OP: v1 watcher:.*WATCHER FIRED/ {print $1}'; }
failure_ids() { user_messages "$1" | awk -F'\t' '$2 ~ /^FIRSTMATE_OP: v1 watcher:.*WATCHER FAILURE/ {print $1}'; }
guard_ids() { user_messages "$1" | awk -F'\t' '$2 ~ /^FIRSTMATE_OP: v1 turn-end-guard:/ {print $1}'; }
nudge_ids() { user_messages "$1" | awk -F'\t' '$2 ~ /^FIRSTMATE_OP: v1 session-start:/ {print $1}'; }
count() { grep -c . || true; }
# The lead's journaled admissions (exact message IDs) in its effective state.
journal_ids() {
  local f
  for f in "$PRIMARY"/state/.opencode-v2-admissions/*/msg_*.json; do
    [ -f "$f" ] || continue
    jq -r 'select(.phase == "admitted" or .phase == "acknowledged") | .id' "$f" 2>/dev/null
  done
}
# Row-bearing canonical acks (seq > 0) count handled queued wakes. A no-row
# recovery presentation (rearm-resurface after a watcher death) acks
# through 0 under its own recovery generation and is counted separately.
acks() { local n; n=$(grep -c '^acked [1-9]' "$LAB/handled.log" 2>/dev/null) || true; echo "${n:-0}"; }
resurfaces() { awk '$1 == "acked" && $2 == 0 {print $3}' "$LAB/handled.log" 2>/dev/null | sort -u | count; }
resurfaces_above() { [ "$(resurfaces)" -gt "$1" ]; }
watchers() { pgrep -f "^bash $PRIMARY/bin/fm-watch.sh" | count; }
arms() { pgrep -f "$PRIMARY/bin/fm-watch-arm.sh" | count; }
watch_pid() { cat "$PRIMARY/state/.watch.lock/pid" 2>/dev/null || echo none; }
beacon_age() { local m; m=$(stat -c %Y "$PRIMARY/state/.last-watcher-beat" 2>/dev/null) || { echo 9999; return; }; echo $(( $(date +%s) - m )); }
queue_rows() { local n; n=$(grep -c . "$PRIMARY/state/.wake-queue" 2>/dev/null) || true; echo "${n:-0}"; }
record() { (cd "$LAB" && isolated node "$PRIMARY/bin/fm-opencode-v2-owner.mjs" read "$LEAD" 2>/dev/null); }
field() { record | jq -r --arg f "$1" '.[$f] // "none"'; }
one_supervisor() { [ "$(watchers)" = 1 ] && [ "$(arms)" = 1 ] && [ "$(beacon_age)" -le 5 ]; }
acks_above() { [ "$(acks)" -gt "$1" ]; }
native_log_errors() { grep -h 'plugin=firstmate.native.v2' "$LAB"/xdg/data/shuvcode/log/*.log 2>/dev/null | grep -o 'stage=[a-z]* [^ ]* error="[^"]*"' ; }

# The native TUI process: the exact ELF executable attached to the lead session.
tui_is_owner() {  # <pid>: the owner record names a live native TUI for this lead
  local pid=$1
  [ -n "$pid" ] && [ "$pid" != none ] && kill -0 "$pid" 2>/dev/null || return 1
  [ "$(readlink "/proc/$pid/exe")" = "$SC" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q -- "--session $LEAD" || return 1
  ! tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q ' serve '
}
lock_is_tui() { local o; o=$(field ownerPID); [ "$(cat "$PRIMARY/state/.lock" 2>/dev/null)" = "$o" ] && tui_is_owner "$o"; }
claimed() { case "$(field lifecycle)" in claimed|active) tui_is_owner "$(field ownerPID)" ;; *) return 1 ;; esac; }
retired() { [ "$(field lifecycle)" = retired ]; }

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
  wait_until 80 claimed
}
session_start() {  # canonical session start in the lead; ready when .lock is the TUI
  prompt "$LEAD" "RUN: bin/fm-session-start.sh > $LAB/session-start.out 2>&1"
  wait_until 120 lock_is_tui
}
# Inject one status change and wait for one canonical ack. Prints
# "<handled> <new-wake-ids> <journaled-of-new> <new-guard> <watchers> <beacon> <rows> <new-failure-prompts>".
one_wake() {  # <label> [tries]
  local a0 w0 g0 f0 new journaled=0 id ok=0 rows
  a0=$(acks); w0=$(wake_ids "$LEAD"); g0=$(guard_ids "$LEAD" | count)
  f0=$(failure_ids "$LEAD" | count)
  printf 'done: %s\n' "$1" >> "$PRIMARY/state/lab.status"
  wait_until "${2:-120}" acks_above "$a0" && ok=1
  wait_until 20 one_supervisor || true
  new=$(comm -13 <(printf '%s\n' "$w0" | sort) <(wake_ids "$LEAD" | sort) | grep . || true)
  for id in $new; do journal_ids | grep -qx "$id" && journaled=$((journaled + 1)); done
  rows=$(queue_rows)
  printf '%s %s %s %s %s %s %s %s\n' "$((ok ? $(acks) - a0 : 0))" "$(printf '%s\n' "$new" | count)" "$journaled" \
    "$(( $(guard_ids "$LEAD" | count) - g0 ))" "$(watchers)" "$(beacon_age)" "${rows:-0}" "$(( $(failure_ids "$LEAD" | count) - f0 ))"
}
wake_ok() {  # <label> [tries]
  local out handled ids journaled guard live beacon rows failures
  out=$(one_wake "$@")
  printf '%s: %s\n' "$1" "$out" >> "$LAB/cycles.log"
  read -r handled ids journaled guard live beacon rows failures <<< "$out"
  [ "$handled" = 1 ] && [ "$ids" = 1 ] && [ "$journaled" = 1 ] && [ "$guard" = 0 ] \
    && [ "$live" = 1 ] && [ "$beacon" -le 5 ] && [ "$rows" = 0 ] && [ "$failures" = 0 ]
}

# --- activation, session start, first arm ---------------------------------------
LEAD=$(create_session "$PRIMARY")
[ -n "$LEAD" ] && [ "$LEAD" != null ] || fail "could not create the lead session"
printf '%s\n' "$LEAD" > "$LAB/lead.id"
start_tui || fail "the native lead TUI never published its exact claim"
TUI_PID=$(field ownerPID)
CLAIM=$(field claimID)
v2_track "$TUI_PID"
have_nudge() { [ "$(nudge_ids "$LEAD" | count)" -ge 1 ]; }
wait_until 40 have_nudge || live_fail "the activated TUI did not nudge session start"
session_start || fail "session start did not make native .lock the activated TUI PID $TUI_PID"
pass "session start makes native .lock the activated TUI process PID ($TUI_PID)"
g0=$(guard_ids "$LEAD" | count)
a0=$(acks)
prompt "$LEAD" "RUN: printf 'kind=scout\\n' > state/lab.meta; printf 'working: started\\n' > state/lab.status"
if wait_until 160 acks_above "$a0" && wait_until 20 one_supervisor && [ "$(guard_ids "$LEAD" | count)" = "$g0" ]; then
  pass "first arm: one watcher, no turn-end-guard prompt, first wake acknowledged"
else
  live_fail "first arm: acks=$(( $(acks) - a0 )) watchers=$(watchers) arms=$(arms) guard prompts=$(( $(guard_ids "$LEAD" | count) - g0 ))"
fi

# Setup throws only after its first awaits, so judge it once the first arm has
# settled rather than racing the startup nudge.
errors=$(native_log_errors | sort -u | tr '\n' ' ')
if [ -z "$errors" ]; then pass "native TUI entry completed setup"
else live_fail "[D6] native TUI entry setup failed: $errors"; fi

# --- steady succession ------------------------------------------------------------
steady_ok=1
for c in $(seq 1 "${FM_V2_SUCC_CYCLES:-10}"); do
  wake_ok "cycle $c" || { live_fail "steady cycle $c: $(tail -1 "$LAB/cycles.log")"; steady_ok=0; }
done
[ "$(failure_ids "$LEAD" | count)" = 0 ] || live_fail "steady succession emitted WATCHER FAILURE prompts"
[ "$steady_ok" = 1 ] && pass "steady succession: ${FM_V2_SUCC_CYCLES:-10} wakes, each one journaled message ID and one canonical ack, one watcher, fresh beacon, empty queue, zero failure prompts"

# --- kills mid-idle ---------------------------------------------------------------
replaced() { [ "$(watch_pid)" != "$1" ] && one_supervisor; }
for pair in watcher:TERM watcher:KILL arm:TERM; do
  what=${pair%%:*} sig=${pair#*:}
  before=$(watch_pid)
  if [ "$what" = watcher ]; then victim=$before; else victim=$(pgrep -f "$PRIMARY/bin/fm-watch-arm.sh" | head -1); fi
  r0=$(resurfaces)
  kill -"$sig" "$victim" 2>/dev/null
  # An idle watcher's death leaves a row-less downtime episode: the owner
  # must present it exactly once (one generation) and keep one successor
  # [F4-B1]. An arm TERM retires its own watcher and may resurface at most once.
  recovered=1
  if [ "$what" = watcher ]; then
    wait_until 60 resurfaces_above "$r0" || recovered=0
  fi
  wait_until 60 replaced "$before" || recovered=0
  sleep 4   # absence window: a second generation or retire/re-arm loop would show here
  got=$(( $(resurfaces) - r0 ))
  if [ "$what" = watcher ]; then [ "$got" = 1 ] || recovered=0; else [ "$got" -le 1 ] || recovered=0; fi
  one_supervisor || recovered=0
  if [ "$recovered" = 1 ] && wake_ok "after $what $sig"; then
    pass "the $what SIG$sig mid-idle recovers ($got no-row resurface) and the next wake is handled once"
  else
    live_fail "[F4-B1] after $what SIG$sig: resurfaces=$got watchers=$(watchers) arms=$(arms) $(tail -1 "$LAB/cycles.log")"
  fi
done
victim=$(pgrep -f "$PRIMARY/bin/fm-watch-arm.sh" | head -1)
kill -KILL "$victim" 2>/dev/null
out=$(one_wake "after arm KILL" 80)
printf 'after arm KILL: %s\n' "$out" >> "$LAB/cycles.log"
if [ "${out%% *}" = 1 ]; then
  pass "an arm SIGKILL with a surviving watcher does not strand the next wake"
else
  live_fail "[D5/D8] after an arm SIGKILL the orphaned watcher's wake stayed unhandled for 20s (queue rows=$(queue_rows))"
  wake_ok "flush after arm KILL" || live_fail "supervision did not recover after the arm SIGKILL: $(tail -1 "$LAB/cycles.log")"
fi

# --- other root and child sessions --------------------------------------------------
# Start the absence window from a settled watcher (same pid across a poll).
settled() { local p; p=$(watch_pid); one_supervisor && sleep 3 && [ "$(watch_pid)" = "$p" ]; }
wait_until 20 settled || live_fail "supervision never settled before the other-session window: watchers=$(watchers) arms=$(arms)"
before=$(watch_pid)
SUB=$(create_session "$PRIMARY/docs/sub")
UNRELATED=$(create_session "$PRIMARY")
CHILD=$(create_session "$PRIMARY" "$LEAD")
for s in "$SUB" "$UNRELATED" "$CHILD"; do prompt "$s" "unrelated work"; done
others_done() { local s; for s in "$SUB" "$UNRELATED" "$CHILD"; do [ "$(user_messages "$s" | count)" -ge 1 ] || return 1; done; }
wait_until 40 others_done || live_fail "other sessions never accepted their own prompts (fixture vacuous)"
sleep 6   # absence window: a takeover would replace the watcher or prompt another session here
others() { local s n=0; for s in "$SUB" "$UNRELATED" "$CHILD"; do n=$(( n + $(wake_ids "$s" | count) + $(failure_ids "$s" | count) + $(guard_ids "$s" | count) )); done; echo "$n"; }
if [ "$(watch_pid)" = "$before" ] && [ "$(others)" = 0 ] && wake_ok "with other sessions" && [ "$(others)" = 0 ]; then
  pass "subdirectory, unrelated and child sessions neither take over the watcher nor receive wakes"
else
  live_fail "another session disturbed supervision: watcher $before -> $(watch_pid), prompts to others=$(others), $(tail -1 "$LAB/cycles.log")"
fi

# --- server package reload (server lifetime only) -----------------------------------
before=$(watch_pid)
api post /api/location/reload --data '{}' >/dev/null || live_fail "location reload request failed"
if [ "$(field ownerPID)" = "$TUI_PID" ] && [ "$(field claimID)" = "$CLAIM" ] && [ "$(watch_pid)" = "$before" ] \
  && wake_ok "after server package reload"; then
  pass "a server package reload leaves the TUI process, its claim and its watcher lifetime intact and delivery continues"
else
  live_fail "after server package reload: owner $TUI_PID -> $(field ownerPID), claim kept=$([ "$(field claimID)" = "$CLAIM" ] && echo yes || echo no), watcher $before -> $(watch_pid), $(tail -1 "$LAB/cycles.log")"
fi

# --- TUI plugin reload (TUI plugin lifetime only) -----------------------------------
errors0=$(native_log_errors | count)
printf '\n// lab TUI plugin reload\n' >> "$PRIMARY/.opencode/plugins/fm-native-v2/tui.js"
sleep 6   # absence window for a setup failure after the reload
reload_errors=$(native_log_errors | tail -n +"$((errors0 + 1))" | sort -u | tr '\n' ' ')
if [ -z "$reload_errors" ] && kill -0 "$TUI_PID" 2>/dev/null && [ "$(field ownerPID)" = "$TUI_PID" ] \
  && [ "$(field claimID)" = "$CLAIM" ] && lock_is_tui && wait_until 40 one_supervisor && wake_ok "after TUI plugin reload"; then
  pass "a TUI plugin reload keeps the same TUI process and immutable claim, sets up again and delivers the next wake"
else
  live_fail "[D6] after TUI plugin reload: setup errors: ${reload_errors:-none}; tui alive=$(kill -0 "$TUI_PID" 2>/dev/null && echo yes || echo no) claim kept=$([ "$(field claimID)" = "$CLAIM" ] && echo yes || echo no) $(tail -1 "$LAB/cycles.log")"
  wake_ok "flush after TUI plugin reload" >/dev/null 2>&1 || true
fi

# --- owner command reachability -------------------------------------------------------
termctrl send "$TUI" ctrl-p >/dev/null 2>&1
termctrl wait "$TUI" Commands --timeout 5000 >/dev/null 2>&1
termctrl send "$TUI" text:Rebind >/dev/null 2>&1
if termctrl wait "$TUI" 'Rebind Firstmate execution service' --timeout 5000 >/dev/null 2>&1; then
  pass "the documented rebind owner command is reachable in the TUI"
else
  live_fail "[D6] the documented /firstmate-rebind owner command is not registered in the TUI"
fi
termctrl send "$TUI" escape >/dev/null 2>&1

# --- TUI exit and relaunch ------------------------------------------------------------
termctrl stop "$TUI" >/dev/null 2>&1
no_supervisor() { [ "$(watchers)" = 0 ] && [ "$(arms)" = 0 ]; }
if wait_until 40 retired && wait_until 40 no_supervisor && kill -0 "$SERVICE_PID" 2>/dev/null; then
  pass "TUI exit retires the claim and supervision while the shared service keeps running"
else
  live_fail "after TUI exit: lifecycle=$(field lifecycle) watchers=$(watchers) arms=$(arms)"
fi
printf 'done: while the TUI was down\n' >> "$PRIMARY/state/lab.status"
nudges=$(nudge_ids "$LEAD" | count)
start_tui || live_fail "relaunched TUI did not publish its claim"
TUI_PID=$(field ownerPID)
v2_track "$TUI_PID"
more_nudges() { [ "$(nudge_ids "$LEAD" | count)" -gt "$nudges" ]; }
wait_until 60 more_nudges || live_fail "relaunched TUI did not nudge session start without a lead turn"
a0=$(acks)
if session_start && wait_until 160 acks_above "$a0" && wait_until 20 one_supervisor && wake_ok "after relaunch"; then
  pass "a relaunched TUI re-owns .lock, re-arms after session start and handles the held and later wakes"
else
  live_fail "after relaunch: lock=$(cat "$PRIMARY/state/.lock" 2>/dev/null) owner=$(field ownerPID) watchers=$(watchers) acks+=$(( $(acks) - a0 ))"
fi

# --- private serve --stdio lead -----------------------------------------------------------
if [ "${FM_V2_SUCC_PRIVATE:-1}" = 1 ]; then
  termctrl stop "$TUI" >/dev/null 2>&1
  wait_until 40 retired || true
  (cd "$LAB" && isolated "$SC" service stop >/dev/null 2>&1) || true
  service_gone() { ! kill -0 "$SERVICE_PID" 2>/dev/null; }
  wait_until 40 service_gone || live_fail "lab service did not stop before the private-server case"
  PASS=$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')
  printf '%s\n' "$PASS" > "$LAB/private.pass"
  mkfifo "$LAB/lease"
  (cd "$PRIMARY" && isolated OPENCODE_PASSWORD="$PASS" OPENCODE_SERVER_PASSWORD="$PASS" \
    "$SC" serve --stdio --hostname 127.0.0.1 --port 0 < "$LAB/lease" > "$LAB/ready" 2> "$LAB/private.err") &
  bash -c 'exec 3>"$1"; exec sleep 3600' _ "$LAB/lease" </dev/null >/dev/null 2>&1 &
  v2_track $!
  ready() { URL=$(jq -er '.url' "$LAB/ready" 2>/dev/null); }
  wait_until 80 ready || live_fail "private server did not become ready"
  for p in $(pgrep -f "$SC serve --stdio"); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "XDG_STATE_HOME=$LAB/xdg/state" && v2_track "$p"
  done
  printf '%s\n' "$URL" > "$LAB/private.url"
  MODE=private
  if start_tui; then
    v2_track "$(field ownerPID)"
    session_start || true
    after=$(jq -r '.pid // empty' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null)
    spawned=no
    if [ -n "$after" ] && [ "$after" != "$SERVICE_PID" ] && kill -0 "$after" 2>/dev/null; then spawned=yes; fi
    if lock_is_tui && [ "$spawned" = no ]; then
      pass "a lead activated against a private server owns its home"
    else
      live_fail "[D7] a lead activated against a private server was accepted but cannot take its home lock (lock=$(cat "$PRIMARY/state/.lock" 2>/dev/null) owner=$(field ownerPID)); background service started as a side effect: $spawned"
    fi
  else
    pass "a lead against a private server is refused at activation"
  fi
fi

[ "$LIVE_FAILED" -eq 0 ] || exit 1
