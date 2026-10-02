#!/usr/bin/env bash
# Live Herdr detach/attach leg for the OpenCode V2 lead owner (issue #1 live
# qualification step 5; frozen contract: Herdr detach preserves a surviving
# TUI owner, TUI exit retires supervision, not shared-service execution).
#
# Run with FM_OPENCODE_V2_HERDR_LIVE=1. It needs herdr, termctrl, jq and Linux
# /proc process-start tokens.
#
# Every Herdr operation goes through bin/fm-herdr-lab.sh on a generated
# `fm-lab-` session: name, provision, run, teardown. The one exception is the
# interactive client, which the helper's `run` deliberately cannot launch: it
# is started as `herdr --session <lab>` inside a termctrl PTY, only after the
# helper reports that exact lab server running, with the caller's inherited
# Herdr session/pane/socket variables removed so it can never reach the
# default session. Teardown always runs through the helper, which verifies
# the default-session tripwire and the lab's removal.
#
# Owner integration knobs (defaults are a stand-in owner script):
#   FM_V2_HERDR_OWNER_CMD    command typed into the lab pane to start the owner;
#                            later the real shuvcode TUI launch helper
#   FM_V2_HERDR_OWNER_PID_CMD   prints the live owner pid (later: cat <state>/.lock)
#   FM_V2_HERDR_SENTINEL_CMD    exits 0 while the owner's supervision is live
#                               (later: registration active and watcher armed)
#   FM_V2_HERDR_RETIRED_CMD     exits 0 once supervision has retired
#                               (later: registry lifecycle retired, watcher gone)
#   FM_V2_HERDR_OWNER_EXIT_KEYS Herdr key names that exit the owner (default ctrl+c)
#   FM_V2_HERDR_EXEC_CMD     starts the stand-in shared-service execution
#                            process and prints its pid
# Each command runs with LAB exported so it can address lab-local files.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_V2_HERDR_LIVE herdr termctrl jq
[ -r /proc/self/stat ] || { printf 'skip: live: /proc process-start tokens are required\n'; exit 0; }

HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HELPER" ] || fail "Herdr lab helper not executable at $HELPER"
# The helper's own usage text is its contract; read it before any lab call.
"$HELPER" help | grep -q 'Session names must begin with "fm-lab-"' \
  || fail "the lab helper's usage no longer states the fm-lab- naming contract; re-read its header"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-v2-herdr-detach.XXXXXX")
LAB=$(cd -P "$LAB" && pwd -P)
export LAB
SESSION=
PROVISIONED=0
CLIENT=v2herdr$$
EXEC_PID=
FAILED=0
export TERMCTRL_RUNTIME_DIR="$LAB/tc"
mkdir -p "$TERMCTRL_RUNTIME_DIR"

clean_env() {
  env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_ENV -u HERDR_SESSION -u HERDR_STARTUP_CWD "$@"
}
helper() { clean_env "$HELPER" "$@"; }
lab() { helper run "$SESSION" "$@"; }

cleanup() {
  local status=$?
  termctrl stop "$CLIENT" >/dev/null 2>&1 || true
  [ -z "$EXEC_PID" ] || kill "$EXEC_PID" 2>/dev/null || true
  if [ "$PROVISIONED" = 1 ]; then
    if ! helper teardown "$SESSION"; then
      printf 'not ok - lab teardown through the helper failed for %s\n' "$SESSION" >&2
      status=1
    elif helper run "$SESSION" session list --json 2>/dev/null | jq -e --arg n "$SESSION" '.sessions[]? | select(.name == $n)' >/dev/null; then
      printf 'not ok - lab session %s still listed after teardown\n' "$SESSION" >&2
      status=1
    fi
  fi
  [ "$FAILED" -eq 0 ] || status=1
  if [ "$status" -eq 0 ]; then rm -rf "$LAB"; else printf 'note: evidence retained at %s\n' "$LAB" >&2; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

check() {  # <condition-description> <command...>
  local what=$1
  shift
  if "$@"; then pass "$what"; else printf 'not ok - %s\n' "$what" >&2; FAILED=$((FAILED + 1)); return 1; fi
}

start_token() {  # <pid>: field 22 of /proc/<pid>/stat, parsed after the comm field
  local stat
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  stat=${stat##*) }
  printf '%s' "$stat" | awk '{ print $20 }'
}

wait_for() {  # <tries> <command...>
  local tries=$1
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    sleep 0.2
    tries=$((tries - 1))
  done
  return 1
}

# --- stand-in owner and shared execution -----------------------------------
cat > "$LAB/owner.sh" <<'SH'
#!/usr/bin/env bash
# Stand-in TUI owner: publishes its pid and a live supervision sentinel, and
# records retirement when it exits.
printf '%s\n' "$$" > "$LAB/owner.pid"
printf 'live %s\n' "$$" > "$LAB/owner.sentinel"
trap 'rm -f "$LAB/owner.sentinel"; printf "retired %s\n" "$$" > "$LAB/owner.retired"; exit 0' INT TERM HUP
printf 'stand-in owner ready pid=%s\n' "$$"
while :; do sleep 0.2; done
SH
cat > "$LAB/exec.sh" <<'SH'
#!/usr/bin/env bash
# Stand-in shared-service execution: independent of the owner and its pane.
trap 'exit 0' TERM
while :; do date +%s > "$LAB/exec.beat"; sleep 0.2; done
SH
chmod +x "$LAB/owner.sh" "$LAB/exec.sh"

# The defaults are command strings evaluated later with LAB exported.
# shellcheck disable=SC2016
OWNER_CMD=${FM_V2_HERDR_OWNER_CMD:-"LAB='$LAB' bash '$LAB/owner.sh'"}
# shellcheck disable=SC2016
OWNER_PID_CMD=${FM_V2_HERDR_OWNER_PID_CMD:-'cat "$LAB/owner.pid"'}
# shellcheck disable=SC2016
SENTINEL_CMD=${FM_V2_HERDR_SENTINEL_CMD:-'grep -q "^live " "$LAB/owner.sentinel"'}
# shellcheck disable=SC2016
RETIRED_CMD=${FM_V2_HERDR_RETIRED_CMD:-'[ ! -e "$LAB/owner.sentinel" ] && grep -q "^retired " "$LAB/owner.retired"'}
EXIT_KEYS=${FM_V2_HERDR_OWNER_EXIT_KEYS:-ctrl+c}
# shellcheck disable=SC2016
EXEC_CMD=${FM_V2_HERDR_EXEC_CMD:-'setsid bash "$LAB/exec.sh" >/dev/null 2>&1 < /dev/null & printf "%s\n" "$!"'}

owner_pid() { bash -c "$OWNER_PID_CMD" 2>/dev/null | tr -d '[:space:]'; }
sentinel_live() { bash -c "$SENTINEL_CMD" >/dev/null 2>&1; }
retired() { bash -c "$RETIRED_CMD" >/dev/null 2>&1; }
same_process() { [ "$(start_token "$1")" = "$2" ]; }  # <pid> <start-token>
owner_gone() { ! kill -0 "$OWNER" 2>/dev/null; }
exec_progressing() {
  local before
  before=$(cat "$LAB/exec.beat" 2>/dev/null)
  sleep 1
  [ -n "$before" ] && [ "$(cat "$LAB/exec.beat" 2>/dev/null)" != "$before" ]
}

# --- provision the named lab ------------------------------------------------
SESSION=$(helper name v2-detach) || fail "the lab helper could not generate a session name"
case "$SESSION" in fm-lab-*) ;; *) fail "generated lab name '$SESSION' is not an fm-lab- session" ;; esac
[ "$SESSION" != default ] || fail "refusing the default session"
helper provision "$SESSION" || fail "lab provisioning through the helper failed"
PROVISIONED=1
lab status --json | jq -e '.server.running == true' >/dev/null || fail "lab server for $SESSION is not running"
pass "herdr lab $SESSION provisioned through the helper"

WS=$(lab workspace create --cwd "$LAB" --label v2-owner --no-focus) || fail "could not create the lab workspace"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "lab workspace create returned no root pane: $WS"

EXEC_PID=$(LAB=$LAB bash -c "$EXEC_CMD" | tail -1)
if [ -z "$EXEC_PID" ] || ! kill -0 "$EXEC_PID" 2>/dev/null; then fail "stand-in shared execution did not start"; fi
EXEC_TOKEN=$(start_token "$EXEC_PID")

lab pane run "$PANE" "$OWNER_CMD" >/dev/null || fail "could not start the owner in lab pane $PANE"
wait_for 100 sentinel_live || fail "the owner never published its live supervision sentinel"
OWNER=$(owner_pid)
OWNER_TOKEN=$(start_token "$OWNER")
[ -n "$OWNER" ] && [ -n "$OWNER_TOKEN" ] || fail "could not read the owner pid and start token"
pass "owner pid $OWNER is live in lab pane $PANE with its supervision sentinel"

# --- attach a real client, detach, reattach ---------------------------------
attach_client() {
  lab status --json | jq -e '.server.running == true' >/dev/null || fail "refusing to attach: lab server not running"
  termctrl start "$CLIENT" --cols 120 --rows 36 -- \
    env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_ENV -u HERDR_STARTUP_CWD \
    HERDR_SESSION="$SESSION" herdr --session "$SESSION" >/dev/null || fail "termctrl could not start the lab client"
  termctrl wait "$CLIENT" "v2-owner" --timeout 20000 >/dev/null \
    || { termctrl show "$CLIENT" > "$LAB/client-attach.txt" 2>&1; fail "the lab client did not render the owner workspace"; }
}
client_attached() {
  lab status --json 2>/dev/null | jq -e '[.. | objects | select(has("clients")) | .clients] | flatten | length > 0' >/dev/null 2>&1 \
    || termctrl status "$CLIENT" 2>/dev/null | grep -qi 'running'
}

attach_client
check "a real client attached to the lab in a PTY" client_attached
termctrl save "$CLIENT" --format txt --out "$LAB/attached" >/dev/null 2>&1 || true
termctrl send "$CLIENT" ctrl-b text:q >/dev/null || fail "could not send the detach keys"
detached() { ! termctrl status "$CLIENT" 2>/dev/null | grep -qi 'running'; }
check "the client detached with prefix+q" wait_for 50 detached
check "the owner survives detach with the same pid and process-start token" same_process "$OWNER" "$OWNER_TOKEN"
check "the owner's supervision sentinel persists across detach" sentinel_live
[ "$(owner_pid)" = "$OWNER" ] || check "the published owner pid is unchanged after detach" false

termctrl stop "$CLIENT" >/dev/null 2>&1 || true
attach_client
check "the client reattached and renders the owner workspace" client_attached
check "the owner is still the same process after reattach" same_process "$OWNER" "$OWNER_TOKEN"
termctrl stop "$CLIENT" >/dev/null 2>&1 || true

# --- exit the owner: supervision retires, shared execution continues --------
# shellcheck disable=SC2086 # key list is intentionally word-split
lab pane send-keys "$PANE" $EXIT_KEYS >/dev/null || fail "could not send the owner exit keys"
check "owner exit fires the retirement observable" wait_for 100 retired
check "the owner process is gone after exit" wait_for 50 owner_gone
check "the separately started shared execution keeps running with the same start token" \
  same_process "$EXEC_PID" "$EXEC_TOKEN"
check "shared execution is still progressing after owner exit" exec_progressing

[ "$FAILED" -eq 0 ] || exit 1
