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
. "$FM_LIB_DIR/fm-opencode-v2-acceptance-lib.sh"
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
    : keep "$LAB"
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
[ -f "$LAB/slow" ] && sleep "$(cat "$LAB/slow")"
n=$(ls "$LAB"/drain-*.out 2>/dev/null | wc -l)
err=$(bin/fm-wake-drain.sh 2>"$LAB/drain-err.tmp" > "$LAB/drain-$((n+1)).out"; cat "$LAB/drain-err.tmp")
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
import { appendFileSync, existsSync } from "node:fs";
import { dirname } from "node:path";
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
      if (/^\u2063?FIRSTMATE_OP: v1 watcher:.*WATCHER FIRED/.test(last)) cmd = existsSync(dirname(handle) + "/ignore") ? null : `bash ${handle}`;
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
# Native user messages of one session: "<id>\t<first line of text>". The export
# is captured to a file (a pipe truncates large exports at 32 KiB) and must parse
# completely: an unreadable export is recorded and fails the run, never reads
# as zero messages.
user_messages() {
  local out="$LAB/export.$1.json"
  if api get "/api/experimental/session/$1/export" > "$out" \
    && jq -e '.data.messages | type == "array"' "$out" >/dev/null 2>&1; then
    jq -r '[.data.messages[] | select(.type == "user")] | .[] | [.id, ((.text // "") | gsub("\u2063"; "") | split("\n")[0])] | @tsv' "$out"
  else
    printf 'not ok - unreadable session export for %s (%s bytes)\n' "$1" "$(wc -c < "$out")" | tee -a "$LAB/export.failed" >&2
    return 1
  fi
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
watchers() { v2_script_process_count "$PRIMARY/bin/fm-watch.sh"; }
arms() { v2_script_process_count "$PRIMARY/bin/fm-watch-arm.sh"; }
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

# ============ idle lead ends turn without draining; later row must not strand ============
nwakes() { wake_ids "$LEAD" | count; }
nfail() { failure_ids "$LEAD" | count; }
above_w() { [ "$(nwakes)" -gt "$1" ]; }
w0=$(nwakes); a0=$(acks); f0=$(nfail)
touch "$LAB/ignore"
printf 'done: ignored-1\n' >> "$PRIMARY/state/lab.status"
wait_until 120 above_w "$w0" || live_fail "idle: first doorbell never admitted"
sleep 8   # lead answers "ok" with no drain; turn ends idle
w1=$(( $(nwakes) - w0 ))
rm -f "$LAB/ignore"
printf 'done: after-idle\n' >> "$PRIMARY/state/lab.status"
wait_until 200 acks_above "$a0" || live_fail "idle: parked wake stranded behind undrained doorbell (no ack)"
sleep 12
w2=$(( $(nwakes) - w0 )); a2=$(( $(acks) - a0 )); fl=$(( $(nfail) - f0 ))
echo "doorbell ignored (turn ended idle without drain): wake prompts=$w1 ; after new row: wake prompts total=$w2 acks=$a2 failure prompts=$fl queue rows=$(queue_rows)" | tee "$LAB/idle-summary.txt"
[ "$w1" = 1 ] && [ "$w2" = 2 ] && [ "$a2" = 1 ] && [ "$fl" = 0 ] && [ "$(queue_rows)" = 0 ] \
  && pass "live: after an idle lead ends its turn without draining, a new row re-rings exactly one doorbell and one drain retires both" \
  || live_fail "idle re-ring: $(cat "$LAB/idle-summary.txt")"
mkdir -p "$EVID"; cp "$LAB/idle-summary.txt" "$LAB/handled.log" "$EVID/"; for d in "$LAB"/drain-*.out; do cp "$d" "$EVID/"; done
jq '[.data.messages[] | select(.type=="user") | {id, text: ((.text // "") | gsub("⁣";"") | split("\n")[0])}]' "$LAB/export.$LEAD.json" > "$EVID/lead-user-messages.json"
