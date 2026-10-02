#!/usr/bin/env bash
# Shared fixtures for the OpenCode V2 shared-service acceptance suites.
# Sourced by the fm-opencode-v2-*-acceptance suites and the live runners.
#
# Production under test lives in V2_CODE_ROOT (FM_V2_TEST_CODE_ROOT, default
# this checkout): the native package .opencode/plugins/fm-native-v2/{server,tui}.js
# and bin/fm-opencode-v2-owner.mjs. When those are absent the dependent cases
# report "pending", never pass. Set FM_V2_ACCEPT_STRICT=1 to fail pendings.
#
# Process stand-ins come from tests/assets/fm-opencode-v2-native-harness.mjs:
# a service whose own pid is the registered execution service and which parents
# model shells (real /proc ancestry), owners that publish real claims through
# the owner library, and a TUI driver that runs the production TUI entry with a
# genuine activation for its own process.
#
# Registry isolation: sourcing this file exports a disposable token-only
# FM_V2_REGISTRY_NAMESPACE before any production call. Every namespace a case
# creates is retired through the owner library's cleanup-test-namespace and its
# directory removed at exit. The operator's default namespace is never used:
# v2_namespace refuses "default".

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V2_HARNESS="$ROOT/tests/assets/fm-opencode-v2-native-harness.mjs"
V2_CODE_ROOT=$(cd -P "${FM_V2_TEST_CODE_ROOT:-$ROOT}" && pwd -P)
V2_NODE_BIN=$(node -p process.execPath)
V2_PENDING=0
V2_FAILED=0
V2_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-v2-accept.XXXXXX")
V2_NS_BASE="v2t$$$RANDOM"
export FM_V2_REGISTRY_NAMESPACE="${V2_NS_BASE}"
: > "$V2_STATE_DIR/pids"
printf '%s\n' "$FM_V2_REGISTRY_NAMESPACE" > "$V2_STATE_DIR/namespaces"

v2_native_ready() {
  [ -f "$V2_CODE_ROOT/.opencode/plugins/fm-native-v2/server.js" ] \
    && [ -f "$V2_CODE_ROOT/.opencode/plugins/fm-native-v2/tui.js" ] \
    && [ -f "$V2_CODE_ROOT/bin/fm-opencode-v2-owner.mjs" ]
}

v2_pending() {  # <case> <missing interface>
  if [ "${FM_V2_ACCEPT_STRICT:-0}" = 1 ]; then
    printf 'not ok - %s: integration pending (%s)\n' "$1" "$2" >&2
    return 1
  fi
  printf 'pending - %s: integration pending (%s)\n' "$1" "$2"
  return 3
}

v2_require_native() {  # <case>
  v2_native_ready && return 0
  v2_pending "$1" "native V2 package and owner library absent from $V2_CODE_ROOT; set FM_V2_TEST_CODE_ROOT"
}

# Switch the current case to its own disposable namespace.
v2_namespace() {  # <suffix>
  local ns="${V2_NS_BASE}$1"
  [[ "$ns" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] && [ "$ns" != default ] || fail "refusing registry namespace '$ns'"
  export FM_V2_REGISTRY_NAMESPACE="$ns"
  printf '%s\n' "$ns" >> "$V2_STATE_DIR/namespaces"
}

v2_track() { printf '%s\n' "$1" >> "$V2_STATE_DIR/pids"; }

# Every production call made by these fixtures must run in a test namespace.
v2_assert_test_namespace() {
  case "${FM_V2_REGISTRY_NAMESPACE:-default}" in
    default|'') fail "refusing to run production V2 code against the operator's default registry namespace" ;;
  esac
}

v2_teardown() {
  local pid ns dir
  while IFS= read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$V2_STATE_DIR/pids"
  sleep 0.3
  while IFS= read -r pid; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done < "$V2_STATE_DIR/pids"
  if v2_native_ready; then
    sort -u "$V2_STATE_DIR/namespaces" | while IFS= read -r ns; do
      [ -n "$ns" ] && [ "$ns" != default ] || continue
      dir="$HOME/.local/state/shuvbro/opencode-v2/$ns"
      [ -d "$dir" ] || continue
      chmod 700 "$dir" 2>/dev/null
      FM_V2_REGISTRY_NAMESPACE="$ns" "$V2_NODE_BIN" "$V2_CODE_ROOT/bin/fm-opencode-v2-owner.mjs" cleanup-test-namespace >/dev/null 2>&1 \
        || printf 'note: test namespace %s cleanup refused\n' "$ns" >&2
      rm -f "$dir/.claims.lock/pid" 2>/dev/null; rmdir "$dir/.claims.lock" 2>/dev/null
      rmdir "$dir" 2>/dev/null || printf 'note: test namespace directory %s not empty after cleanup\n' "$dir" >&2
    done
  fi
  rm -rf "$V2_STATE_DIR"
}
v2_exit() { local status=$?; v2_teardown; fm_test_cleanup 2>/dev/null; exit "$status"; }
trap v2_exit EXIT

# Run each case in a subshell, counting failures and pendings separately.
v2_run_cases() {  # <case-function>...
  local t rc
  for t in "$@"; do
    rc=0
    ( "$t" ) || rc=$?
    case "$rc" in
      0) ;;
      3) V2_PENDING=$((V2_PENDING + 1)) ;;
      *) V2_FAILED=$((V2_FAILED + 1)) ;;
    esac
  done
  if [ "$V2_FAILED" -ne 0 ]; then
    printf 'not ok - %s case(s) failed, %s pending\n' "$V2_FAILED" "$V2_PENDING" >&2
    return 1
  fi
  [ "$V2_PENDING" -eq 0 ] || printf 'note: %s case(s) pending integration with the frozen V2 interfaces\n' "$V2_PENDING"
  return 0
}

# --- fixtures ---------------------------------------------------------------

v2_make_home() {  # <dir>: an external FM_HOME with state and config
  mkdir -p "$1/state" "$1/config"
  (cd -P "$1" && pwd -P)
}

# A disposable code-root copy whose classifiers a case may break. Only the
# guard classifiers and the files they import are copied.
v2_make_guard_root() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/projects/x"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  cp "$V2_CODE_ROOT"/bin/fm-*-command-policy.mjs "$dir/bin/"
  (cd -P "$dir" && pwd -P)
}

v2_make_linked_root() {  # <primary-dir> <linked-dir>
  git -C "$1" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init >/dev/null 2>&1
  git -C "$1" worktree add -q "$2" 2>/dev/null
  mkdir -p "$2/projects/x"
  (cd -P "$2" && pwd -P)
}

# The service stand-in runs node through a link named `shuvcode` with a trailing
# `--service` argument, so the session-lock ancestry walk sees the same process
# shape (comm shuvcode, a whole --service token) as the real shared service and
# stops there, instead of climbing into the test runner's own ancestry.
V2_SERVICE_EXEC="$V2_STATE_DIR/bin/shuvcode"
mkdir -p "$V2_STATE_DIR/bin"
ln -s "$V2_NODE_BIN" "$V2_SERVICE_EXEC"
export V2_SERVICE_EXEC

# Start a service stand-in; sets V2_SERVICE_PID and V2_SOCKET.
v2_start_service() {  # <dir>
  local dir=$1
  v2_assert_test_namespace
  mkdir -p "$dir"
  [ -f "$dir/sessions.json" ] || printf '{}' > "$dir/sessions.json"
  V2_SOCKET="$dir/svc-$RANDOM.sock"
  "$V2_SERVICE_EXEC" "$V2_HARNESS" service "$V2_CODE_ROOT" "$V2_SOCKET" "$dir/sessions.json" --service > "$dir/service.out" 2>&1 &
  V2_SERVICE_PID=$!
  v2_track "$V2_SERVICE_PID"
  for _ in $(seq 1 100); do
    grep -q '"ready":true' "$dir/service.out" 2>/dev/null && return 0
    sleep 0.05
  done
  fail "service stand-in did not start: $(cat "$dir/service.out")"
}

v2_call() {  # <json>
  "$V2_NODE_BIN" "$V2_HARNESS" call "$V2_SOCKET" "$1"
}

v2_session() {  # <dir> <id> <directory> [parent] [marker-session] [marker-claim]
  local dir=$1 info
  info=$(jq -nc --arg id "$2" --arg d "$3" --arg p "${4:-}" --arg m "${5:-}" --arg c "${6:-}" '
    {id: $id, location: {directory: $d}, metadata: {}}
    + (if $p == "" then {} else {parentID: $p} end)
    + (if $m == "" then {} else {metadata: {firstmateV2Lead: {version: 1, sessionID: $m, claimID: $c}}} end)')
  jq --arg id "$2" --argjson info "$info" '.[$id] = $info' "$dir/sessions.json" > "$dir/sessions.tmp" && mv "$dir/sessions.tmp" "$dir/sessions.json"
}

# Publish a real exact registration through a live owner stand-in; sets
# V2_OWNER_PID and V2_CLAIM. The owner retires on SIGUSR1.
v2_register() {  # <dir> <session> <root> <home>
  local dir=$1 out
  v2_assert_test_namespace
  out="$dir/owner-$2.out"
  "$V2_NODE_BIN" "$V2_HARNESS" owner "$V2_CODE_ROOT" "$V2_SOCKET" "$2" "$3" "$4" "$4/state" "$4/config" > "$out" 2>&1 &
  V2_OWNER_PID=$!
  v2_track "$V2_OWNER_PID"
  for _ in $(seq 1 100); do
    V2_CLAIM=$(head -1 "$out" 2>/dev/null | jq -r '.claimID // empty' 2>/dev/null)
    [ -n "$V2_CLAIM" ] && return 0
    kill -0 "$V2_OWNER_PID" 2>/dev/null || break
    sleep 0.05
  done
  fail "registration through the owner library failed: $(cat "$out")"
}

v2_retire() {  # <dir> <session>
  kill -USR1 "$V2_OWNER_PID"
  for _ in $(seq 1 100); do
    grep -q '"retired"' "$1/owner-$2.out" 2>/dev/null && return 0
    sleep 0.05
  done
  fail "owner retirement did not publish: $(cat "$1/owner-$2.out")"
}

# Run the production guard for one tool event inside the service; prints the
# reply JSON ({reason} or {thrown}).
v2_guard() {  # <session> <command> [tool] [env-json]
  v2_call "$(jq -nc --arg s "$1" --arg c "$2" --arg t "${3:-shell}" --argjson e "${4:-null}" \
    '{op: "denyReason", env: $e, event: {tool: $t, sessionID: $s, id: "call_1", messageID: "msg_1", agent: "build", input: {command: $c}}}')"
}

# Classify a guard reply: allow | classifier:<code> | scope | evaluate | other.
v2_guard_kind() {  # <reply-json>
  printf '%s' "$1" | jq -r '
    if has("thrown") then "evaluate"
    elif .reason == "" then "allow"
    elif (.reason | test("^\\[[A-Za-z0-9_-]+\\] ")) then "classifier:" + (.reason | capture("^\\[(?<c>[A-Za-z0-9_-]+)\\]").c)
    elif (.reason | test("rebind")) then "scope"
    elif (.reason | test("could not evaluate|invalid verdict|unable to evaluate|timed out|signal")) then "evaluate"
    else "other" end'
}

v2_expect_kind() {  # <label> <expected-kind-regex> <reply-json>
  local kind
  kind=$(v2_guard_kind "$3")
  [[ "$kind" =~ ^($2)$ ]] || fail "$1: expected guard outcome '$2', got '$kind' ($3)"
}

# A model shell of <session> inside the service. Prints {code, signal, stdout, stderr}.
v2_shell() {  # <session> <command> [extra-env-json]
  v2_call "$(jq -nc --arg s "$1" --arg c "$2" --argjson e "${3:-null}" '{op: "shell", sessionID: $s, command: $c, extraEnv: $e}')"
}

# The frozen helper routing environment a lead's model shell carries.
v2_lead_env() {  # <home>
  jq -nc --arg r "$V2_CODE_ROOT" --arg h "$1" --arg ns "$FM_V2_REGISTRY_NAMESPACE" \
    '{FM_ROOT_OVERRIDE: $r, FM_HOME: $h, FM_STATE_OVERRIDE: ($h + "/state"), FM_CONFIG_OVERRIDE: ($h + "/config"), FM_V2_REGISTRY_NAMESPACE: $ns}'
}

# Run the production TUI entry under a genuine activation for the driver's own
# process. <spec> is JSON merged over the defaults; writes <out>.
v2_tui() {  # <dir> <spec-json> <out>
  local dir=$1
  v2_assert_test_namespace
  printf '%s' "$V2_SOCKET" > "$dir/socket"
  jq -n --argjson s "$2" --arg sf "$dir/sessions.json" '{sessionsFile: $sf} + $s' > "$dir/tui-spec.json"
  "$V2_NODE_BIN" "$V2_HARNESS" tui "$V2_CODE_ROOT" "$dir/socket" "$dir/tui-spec.json" "$3" > "$dir/tui.log" 2>&1
}
