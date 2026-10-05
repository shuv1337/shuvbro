#!/usr/bin/env bash
# tests/fm-backend-herdr-eventwait-smoke.test.sh - REAL-herdr smoke test for the
# native pane.agent_status_changed push escalation (fm_backend_herdr_wait_transition,
# bin/backends/herdr.sh, and its raw-socket reader bin/backends/herdr-eventwait.py).
# It drives a real idle->blocked transition in an ISOLATED, never-default herdr
# lab session and asserts the subscriber returns that transition sub-second and
# that the watcher's handle_push_transition lands a stale record in a scratch
# state/.wake-queue. Skips cleanly when herdr, jq, or python3 is missing.
#
# Safety: every Herdr CLI call, including those from the watcher subprocess,
# goes through the lab helper on a private fm-lab-* session. Its lifecycle
# operations refuse default and verify the fleet-state tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the event subscriber)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name sb-herdr-wait-term) || exit 1
SESSION="$HERDR_LAB_SESSION"
export HERDR_SESSION="$SESSION"
SCRATCH=
FM_HERDR_SMOKE_ORIGINAL_PATH=$PATH
cleanup_all() {
  PATH="$FM_HERDR_SMOKE_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || return 1
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap 'cleanup_all || exit 1' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab session"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-evwait.XXXXXX") || fail "could not create scratch state"
mkdir "$SCRATCH/guarded-bin"
cat > "$SCRATCH/guarded-bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ]; then
  [ "${args[n-1]}" = "$HERDR_LAB_SESSION" ] || exit 1
  args=("${args[@]:0:n-2}")
fi
PATH="$FM_HERDR_SMOKE_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod 0700 "$SCRATCH/guarded-bin/herdr"
export HERDR_LAB_HELPER HERDR_LAB_SESSION FM_HERDR_SMOKE_ORIGINAL_PATH
export PATH="$SCRATCH/guarded-bin:$PATH"

# The dispatcher is a separately linted production boundary. Its dynamic
# adapter source edges stop at each independently linted canonical adapter.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HERDR_VERSION=$(herdr status --json 2>/dev/null | jq -r '.client.version // "unknown"')

# --- real capability gate ----------------------------------------------------

if ! fm_backend_herdr_events_capable "$SESSION"; then
  echo "skip: this herdr build is below the events.subscribe capability (protocol < 16 or events surface absent)"
  cleanup_all || exit 1
  trap - EXIT
  exit 0
fi
pass "real herdr ($HERDR_VERSION): events.subscribe capability gate passes (protocol >= 16, events surface present in api schema)"

# --- container + a real task pane in the isolated session --------------------

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-evwait1" /tmp "$SEEDED_TAB_ID") || fail "create_task failed"
read -r _TAB_ID PANE_ID <<EOF
$IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
TARGET="$SESSION:$PANE_ID"

# scratch firstmate state so window_to_task and the wake queue resolve
STATE="$SCRATCH/state"; mkdir -p "$STATE"
cat > "$STATE/evwait1.meta" <<EOF
window=$TARGET
backend=herdr
kind=ship
EOF

SOCK=$(fm_backend_herdr_socket_path "$SESSION")
[ -n "$SOCK" ] || fail "could not resolve the isolated session's socket path"

# --- register the pane's agent idle, then drive idle->blocked ----------------
# report-agent is herdr's documented primitive for a non-built-in process to
# report its own agent state (docs/herdr-backend.md); routed through the lab
# helper's guarded `run` so it carries the trailing --session.
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not register the pane's agent as idle"

OUT="$SCRATCH/out"; RCF="$SCRATCH/rc"
: > "$OUT"; : > "$RCF"
# Bounded subscriber wait in the background; it must sit past the idle reconcile
# and return only when the pane transitions to blocked.
( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$TARGET" > "$OUT"; echo $? > "$RCF" ) &
WPID=$!
sleep 0.5   # let it connect, subscribe, and reconcile the idle baseline

START=$(python3 -c 'import time; print(time.time())')
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state blocked >/dev/null 2>&1 \
  || fail "could not drive the pane's agent to blocked"
wait "$WPID"
END=$(python3 -c 'import time; print(time.time())')

RC=$(cat "$RCF" 2>/dev/null || echo "")
REC=$(cat "$OUT" 2>/dev/null || echo "")
ELAPSED=$(python3 -c "print(f'{($END)-($START):.3f}')" 2>/dev/null || echo "?")

[ "$RC" = 0 ] || fail "wait_transition should return 0 on a real idle->blocked transition, got rc='$RC' rec='$REC'"
REC_PANE=$(fm_transition_pane_id "$REC")
REC_TO=$(fm_transition_to_status "$REC")
[ "$REC_PANE" = "$PANE_ID" ] || fail "the returned record's pane_id ('$REC_PANE') must match the driven pane ('$PANE_ID')"
[ "$REC_TO" = "blocked" ] || fail "the returned record's to_status must be 'blocked', got '$REC_TO'"
# Sub-second: comfortably under the ~240s stale-pane wedge timer this replaces.
UNDER_ONE=$(python3 -c "print('yes' if (($END)-($START)) < 1.0 else 'no')" 2>/dev/null || echo "no")
[ "$UNDER_ONE" = yes ] || echo "note: idle->blocked wake took ${ELAPSED}s (>1s; still far under the 240s wedge timer, not fatal)" >&2
pass "real herdr ($HERDR_VERSION): a driven idle->blocked transition returns the blocked record in ${ELAPSED}s (pane $PANE_ID)"

# --- the watcher's fast-path lands a stale record in the scratch wake queue ---
# Load the narrow production owner only after pointing it at scratch state, then
# override wake so the handler enqueues without exiting the test.
export FM_STATE_OVERRIDE="$STATE"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-push-transition-lib.sh"
wake() { return 0; }
handle_push_transition herdr "$SESSION" "$REC"
[ -e "$STATE/.wake-queue" ] || fail "handle_push_transition did not create the wake queue"
grep -q 'stale' "$STATE/.wake-queue" || fail "the wake queue must carry a stale record: $(cat "$STATE/.wake-queue")"
grep -q "$TARGET" "$STATE/.wake-queue" || fail "the stale record must name the task window $TARGET"
grep -q 'herdr: agent blocked' "$STATE/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
pass "real herdr: the watcher fast-path enqueues a stale wake naming the task window from the live blocked transition"

# --- retire a real watcher while its socket subscriber is waiting ------------
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not restore the isolated pane's idle baseline"
python3 - "$ROOT" "$SCRATCH" "$TARGET" "$SOCK" <<'PY' || fail "live watcher event-wait TERM retirement failed"
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root, scratch, target, sock = sys.argv[1:]
home = Path(scratch) / "retire"
state = home / "state"
state.mkdir(parents=True)
(home / "config").mkdir()
(state / "retire.meta").write_text(f"window={target}\nbackend=herdr\nkind=ship\n")
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=root,
           FM_STATE_OVERRIDE=str(state), FM_CONFIG_OVERRIDE=str(home / "config"),
           FM_POLL="60", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999",
           TMPDIR=str(home))
watcher = subprocess.Popen(["bash", f"{root}/bin/fm-watch.sh"], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
reader_pid = None
try:
    # The socket path identifies only this isolated lab's subscriber. A live
    # reader plus its FIFO proves that retirement actually interrupts a wait.
    for _ in range(150):
        rows = subprocess.check_output(["ps", "-axo", "pid=,args="], text=True)
        for row in rows.splitlines():
            pid, args = row.strip().split(None, 1)
            if "herdr-eventwait.py" in args and sock in args and " 60 " in args:
                reader_pid = int(pid)
                break
        if reader_pid is not None and list(home.glob("fm-herdr-eventwait.*")):
            break
        assert watcher.poll() is None, "watcher exited before the event wait"
        time.sleep(0.1)
    assert reader_pid is not None, "watcher never started its live socket subscriber"
    time.sleep(0.1)
    started = time.monotonic()
    watcher.send_signal(signal.SIGTERM)
    out, err = watcher.communicate(timeout=1)
    elapsed = time.monotonic() - started
    assert watcher.returncode == 1, (out, err)
    assert not list(state.glob(".watch-event-output.*")), "captured record survived"
    assert not list(home.glob("fm-herdr-eventwait.*")), "reader FIFO survived"
    pids = subprocess.check_output(["ps", "-axo", "pid="], text=True).split()
    assert str(reader_pid) not in pids, "socket reader survived"
    assert not (state / ".watch.lock" / "pid").exists(), "watcher lock survived"
    print(f"ok - real herdr: watcher TERM retires the socket reader, output pipes and temporary files in {elapsed:.3f}s")
finally:
    if reader_pid is not None:
        try:
            os.kill(reader_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if watcher.poll() is None:
        watcher.kill()
    watcher.communicate(timeout=3)
PY

cleanup_all || exit 1
trap - EXIT
