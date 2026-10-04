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

v2_assert_test_namespace() {
  case "${FM_V2_REGISTRY_NAMESPACE:-}" in
    default|'') printf 'refusing unset/default V2 test registry namespace\n' >&2; return 1 ;;
  esac
  [[ "$FM_V2_REGISTRY_NAMESPACE" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || { printf 'refusing invalid V2 test registry namespace\n' >&2; return 1; }
  local registry_home
  registry_home=$(node -p 'require("os").userInfo().homedir') || return 1
  if [ "${1:-}" != --existing ] && [ -e "$registry_home/.local/state/shuvbro/opencode-v2/$FM_V2_REGISTRY_NAMESPACE" ]; then
    if ! { [ -n "${FM_V2_TEST_NAMESPACE_FILE:-}" ] && [ -f "$FM_V2_TEST_NAMESPACE_FILE" ] && grep -qxF "$FM_V2_REGISTRY_NAMESPACE" "$FM_V2_TEST_NAMESPACE_FILE"; }; then
      printf 'refusing non-fresh unmanaged V2 test registry namespace\n' >&2; return 1
    fi
  fi
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --assert-test-namespace ]; then
  v2_assert_test_namespace "${2:-}"
  exit $?
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V2_HARNESS="$ROOT/tests/assets/fm-opencode-v2-native-harness.mjs"
V2_CODE_ROOT=$(cd -P "${FM_V2_TEST_CODE_ROOT:-$ROOT}" && pwd -P)
V2_NODE_BIN=$(node -p process.execPath)
V2_PENDING=0
V2_FAILED=0
V2_STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-v2-accept.XXXXXX")
V2_NS_BASE="v2t$$$RANDOM"
V2_REGISTRY_HOME=$("$V2_NODE_BIN" -p 'require("os").userInfo().homedir') || return 1
[ ! -e "$V2_REGISTRY_HOME/.local/state/shuvbro/opencode-v2/$V2_NS_BASE" ] || { printf 'refusing a colliding V2 test namespace\n' >&2; exit 1; }
export FM_V2_REGISTRY_NAMESPACE="${V2_NS_BASE}"
# Fixture boundary: an ambient native session identity or activation (for
# example from the developer's own shuvcode shell) must never reach production
# helpers run by these fixtures.
unset OPENCODE_SESSION_ID FM_V2_ACTIVATION OPENCODE OPENCODE_TERMINAL
: > "$V2_STATE_DIR/pids"
printf '%s\n' "$FM_V2_REGISTRY_NAMESPACE" > "$V2_STATE_DIR/namespaces"
export FM_V2_TEST_NAMESPACE_FILE="$V2_STATE_DIR/namespaces"

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
  v2_assert_test_namespace || fail "refusing a non-fresh V2 case namespace"
  printf '%s\n' "$ns" >> "$V2_STATE_DIR/namespaces"
}

# Fixture processes are tracked by pid plus /proc start token, so teardown can
# never signal a reused pid that no longer belongs to this run.
v2_start_token() { local stat; stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; stat=${stat##*) }; printf '%s' "$stat" | awk '{print $20}'; }
v2_track() { printf '%s %s\n' "$1" "$(v2_start_token "$1" || echo 0)" >> "$V2_STATE_DIR/pids"; }

# As in the TUI suite's watchers_step, Bash command substitutions inherit
# the script's command line but are not additional watcher/arm processes.
v2_script_process_count() {  # <absolute script path>
  local pid parent cmd parent_cmd stat n=0
  while IFS= read -r pid; do
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
    case "$cmd" in "bash $1 "*) ;; *) continue ;; esac
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
    stat=${stat##*) }; parent=${stat#* }; parent=${parent%% *}
    parent_cmd=$(tr '\0' ' ' < "/proc/$parent/cmdline" 2>/dev/null) || parent_cmd=''
    [ "$cmd" = "$parent_cmd" ] && continue
    n=$((n + 1))
  done < <(pgrep -f '/bin/fm-watch(-arm)?\.sh( |$)' || true)
  printf '%s\n' "$n"
}

v2_confirm_singleton() {  # <predicate command...>; three consecutive samples
  local stable=0 _
  for _ in $(seq 1 12); do
    if "$@"; then stable=$((stable + 1)); else stable=0; fi
    [ "$stable" -ge 3 ] && return 0
    sleep 0.25
  done
  return 1
}

V2_TEARDOWN_FAILED=0
v2_teardown() {
  local pid start ns dir live _
  while read -r pid start; do
    [ -n "$pid" ] && [ "$(v2_start_token "$pid")" = "$start" ] && kill "$pid" 2>/dev/null
  done < "$V2_STATE_DIR/pids"
  for _ in $(seq 1 30); do
    live=0
    while read -r pid start; do [ -n "$pid" ] && [ "$(v2_start_token "$pid")" = "$start" ] && live=1; done < "$V2_STATE_DIR/pids"
    [ "$live" = 1 ] || break
    sleep 0.1
  done
  while read -r pid start; do
    if [ -n "$pid" ] && [ "$(v2_start_token "$pid")" = "$start" ]; then
      printf 'note: fixture process %s survived TERM; killing\n' "$pid" >&2
      kill -9 "$pid" 2>/dev/null
      V2_TEARDOWN_FAILED=1
    fi
  done < "$V2_STATE_DIR/pids"
  if v2_native_ready; then
    while IFS= read -r ns; do
      [ -n "$ns" ] && [ "$ns" != default ] || continue
       dir="$V2_REGISTRY_HOME/.local/state/shuvbro/opencode-v2/$ns"
      [ -d "$dir" ] || continue
      chmod 700 "$dir" 2>/dev/null
      if ! FM_V2_REGISTRY_NAMESPACE="$ns" "$V2_NODE_BIN" "$V2_CODE_ROOT/bin/fm-opencode-v2-owner.mjs" cleanup-test-namespace >/dev/null 2>"$V2_STATE_DIR/cleanup.err"; then
        # Retain the namespace as evidence and fail; never delete around the owner.
        printf 'not ok - test namespace %s cleanup refused (retained): %s\n' "$ns" "$(cat "$V2_STATE_DIR/cleanup.err")" >&2
        V2_TEARDOWN_FAILED=1
        continue
      fi
      # The owner command removes the namespace directory when it is empty.
      [ -d "$dir" ] || continue
      rmdir "$dir" 2>/dev/null || printf 'note: test namespace directory %s not empty after cleanup: %s\n' "$dir" "$(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f ')" >&2
    done < <(sort -u "$V2_STATE_DIR/namespaces")
  fi
  rm -rf "$V2_STATE_DIR"
}
v2_exit() {
  local status=$?
  v2_teardown
  [ "$V2_TEARDOWN_FAILED" = 0 ] || [ "$status" -ne 0 ] || status=1
  fm_test_cleanup 2>/dev/null
  exit "$status"
}
trap v2_exit EXIT

# Run each case in a subshell, counting failures and pendings separately.
v2_run_cases() {  # <case-function>...
  local t rc
  for t in "$@"; do
    # FM_V2_ONLY=<regex> runs a subset while developing; never set it in CI.
    [ -z "${FM_V2_ONLY:-}" ] || [[ "$t" =~ $FM_V2_ONLY ]] || continue
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
# Each case directory has one stable endpoint and private native state: a
# second start in the same directory is a restart at the same endpoint, which
# replaces the managed registration (new pid, new credential). Sets
# V2_SERVICE_URL, V2_NATIVE_STATE and V2_NATIVE_BIN (the fixture CLI).
v2_start_service() {  # <dir>
  local dir=$1
  v2_assert_test_namespace
  mkdir -p "$dir"
  [ -f "$dir/sessions.json" ] || printf '{}' > "$dir/sessions.json"
  export V2_NATIVE_STATE="$dir/native" V2_NATIVE_BIN="$dir/native-bin"
  if [ ! -d "$V2_NATIVE_STATE" ]; then
    mkdir -m 700 "$V2_NATIVE_STATE" "$V2_NATIVE_BIN"
    printf '%s\n' "http://127.0.0.1:$((20000 + RANDOM % 40000))" > "$V2_NATIVE_STATE/.endpoint"
    printf '#!/usr/bin/env bash\nexec %q %q cli %q "$@"\n' "$V2_NODE_BIN" "$V2_HARNESS" "$V2_NATIVE_STATE" > "$V2_NATIVE_BIN/shuvcode"
    chmod 700 "$V2_NATIVE_BIN/shuvcode"
  fi
  V2_SERVICE_URL=$(cat "$V2_NATIVE_STATE/.endpoint")
  export V2_SERVICE_URL
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
# V2_OWNER_PID and V2_CLAIM. The owner retires on SIGUSR1. It runs through the
# `shuvcode` link like the real activated lead, so lock-holder liveness sees a
# shuvcode harness even where Node renames its main thread to MainThread.
v2_register() {  # <dir> <session> <root> <home>
  local dir=$1 out
  v2_assert_test_namespace
  out="$dir/owner-$2.out"
  "$V2_SERVICE_EXEC" "$V2_HARNESS" owner "$V2_CODE_ROOT" "$V2_SOCKET" "$2" "$3" "$4" "$4/state" "$4/config" > "$out" 2>&1 &
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

# Classify a guard reply by its reason:
#   allow                 no lead policy applied
#   classifier:<code>     a production classifier denied with its typed code
#   scope                 protective refusal naming an explicit rebind
#   evaluate-unavailable  a classifier exited abnormally (signal, timeout, crash)
#   evaluate-invalid      a classifier returned a malformed verdict
#   crash                 the guard itself threw (never an expected outcome)
#   other                 any other reason (asserted by exact text where used)
v2_guard_kind() {  # <reply-json>
  printf '%s' "$1" | jq -r '
    if has("thrown") then "crash"
    elif .reason == "" then "allow"
    elif (.reason | test("^\\[[A-Za-z0-9_-]+\\] ")) then "classifier:" + (.reason | capture("^\\[(?<c>[A-Za-z0-9_-]+)\\]").c)
    elif (.reason | test("rebind")) then "scope"
    elif (.reason | test("could not evaluate this command")) then "evaluate-unavailable"
    elif (.reason | test("returned an invalid verdict")) then "evaluate-invalid"
    else "other" end'
}

v2_expect_kind() {  # <label> <expected-kind-regex> <reply-json>
  local kind
  kind=$(v2_guard_kind "$3")
  [[ "$kind" =~ ^($2)$ ]] || fail "$1: expected guard outcome '$2', got '$kind' ($3)"
}

# A model shell of <session> inside the service. Prints {code, signal, stdout, stderr}.
v2_shell() {  # <session> <command> [extra-env-json] [workdir]
  v2_call "$(jq -nc --arg s "$1" --arg c "$2" --argjson e "${3:-null}" --arg w "${4:-}" '{op: "shell", sessionID: $s, command: $c, extraEnv: $e} + (if $w == "" then {} else {workdir: $w} end)')"
}

# The frozen helper routing environment a lead's model shell carries.
v2_lead_env() {  # <home>
  jq -nc --arg r "$V2_CODE_ROOT" --arg h "$1" --arg ns "$FM_V2_REGISTRY_NAMESPACE" \
    '{FM_ROOT_OVERRIDE: $r, FM_HOME: $h, FM_STATE_OVERRIDE: ($h + "/state"), FM_CONFIG_OVERRIDE: ($h + "/config"), FM_V2_REGISTRY_NAMESPACE: $ns}'
}

# Run the production TUI entry under a genuine activation for the driver's own
# process. <spec> is JSON merged over the defaults; writes <out>.
v2_tui() {  # <dir> <spec-json> <out> [spec-file-name]
  local dir=$1 specfile="$1/${4:-tui-spec.json}"
  v2_assert_test_namespace
  printf '%s' "$V2_SOCKET" > "$dir/socket"
  jq -n --argjson s "$2" --arg sf "$dir/sessions.json" '{sessionsFile: $sf} + $s' > "$specfile"
  "$V2_NODE_BIN" "$V2_HARNESS" tui "$V2_CODE_ROOT" "$dir/socket" "$specfile" "$3" > "$specfile.log" 2>&1
}

# Background form for concurrent owners; sets V2_TUI_PID.
v2_tui_bg() {  # <dir> <spec-json> <out> <spec-file-name>
  v2_tui "$@" &
  # shellcheck disable=SC2034 # Read by the acceptance tests that source this lib.
  V2_TUI_PID=$!
}
