#!/usr/bin/env bash
# drive-arm-term.sh <repo-root> <label>: start the real fm-watch-arm.sh with a
# 60s poll in an isolated home, send it TERM while it idles in its poll wait,
# and measure how long until the arm's output pipe closes (what a plugin waits on).
set -u
ROOT=$1; LABEL=$2
case_dir=$(mktemp -d "${TMPDIR:-/tmp}/arm-term-$LABEL.XXXX")
mkdir -p "$case_dir/state" "$case_dir/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/tmux"; chmod +x "$case_dir/fakebin/tmux"
fifo="$case_dir/arm.fifo"; out="$case_dir/arm.out"; eof="$case_dir/eof"
mkfifo "$fifo"
{ cat "$fifo" > "$out"; touch "$eof"; } &
PATH="$case_dir/fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_POLL=60 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-arm.sh" > "$fifo" 2>&1 &
arm=$!
for _ in $(seq 80); do grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break; sleep 0.1; done
watcher=$(cat "$case_dir/state/.watch.lock/pid" 2>/dev/null)
echo "[$LABEL] arm pid=$arm watcher pid=$watcher; started line: $(grep -F 'watcher: started' "$out" | head -1)"
sleep 2
echo "[$LABEL] processes before TERM:"; ps -o pid,ppid,etimes,args --ppid "$watcher" 2>/dev/null | sed 's/^/    /'
SLEEP_PID=$(pgrep -x sleep -P "$watcher" | head -1); t0=$(date +%s.%N); kill -TERM "$arm"
for _ in $(seq 700); do [ -e "$eof" ] && break; sleep 0.1; done
t1=$(date +%s.%N)
wait "$arm"; rc=$?
if [ -e "$eof" ]; then printf '[%s] arm output pipe closed %.2fs after TERM (arm exit=%s)\n' "$LABEL" "$(echo "$t1 - $t0" | bc)" "$rc"
else echo "[$LABEL] arm output pipe STILL OPEN 70s after TERM (arm exit=$rc)"; fi
if kill -0 "$watcher" 2>/dev/null; then echo "[$LABEL] watcher pid $watcher still alive"; else echo "[$LABEL] watcher pid $watcher gone"; fi
leftover=$(ps -o pid=,args= -p "$(ps -o pid= --ppid "$watcher" 2>/dev/null; echo "${SLEEP_PID:-0}")" 2>/dev/null | grep "sleep 60"); echo "[$LABEL] cycle sleep pid ${SLEEP_PID:-?} after retirement: ${leftover:-reaped}"
echo "[$LABEL] arm output:"; sed 's/^/    /' "$out"
rm -rf "$case_dir"
