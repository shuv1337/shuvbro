#!/usr/bin/env bash
# Live driver: run the real bin/fm-watch-arm.sh from a given revision with its
# fm-watch.sh replaced by a watcher that ignores TERM (what a bash-dropped
# signal trap leaves behind), TERM the arm, and time whether it returns.
set -u
rev=$1 work=$2 repo=$3
mkdir -p "$work/$rev/bin" "$work/$rev/state"
git -C "$repo" archive "$rev" bin | tar -x -C "$work/$rev"
cat > "$work/$rev/bin/fm-watch.sh" <<'STUB'
#!/usr/bin/env bash
trap '' TERM INT HUP   # the dropped-trap survivor
printf '%s\n' "$$" > "$READY"
while :; do sleep 0.2; done
STUB
chmod +x "$work/$rev/bin/fm-watch.sh"
READY="$work/$rev/ready" FM_STATE_OVERRIDE="$work/$rev/state" FM_ARM_CONFIRM_TIMEOUT=60 \
  "$work/$rev/bin/fm-watch-arm.sh" > "$work/$rev/arm.out" 2> "$work/$rev/arm.err" &
arm=$!
for _ in $(seq 100); do [ -s "$work/$rev/ready" ] && break; sleep 0.05; done
watcher=$(cat "$work/$rev/ready")
echo "[$rev] arm pid=$arm watcher pid=$watcher (watcher ignores TERM)"
sleep 1
echo "[$rev] $(date +%T) kill -TERM arm"
kill -TERM "$arm"
start=$SECONDS; returned=no
while [ $((SECONDS - start)) -lt 30 ]; do
  if ! kill -0 "$arm" 2>/dev/null; then returned=yes; break; fi
  sleep 0.2
done
if [ "$returned" = yes ]; then wait "$arm"; rc=$?; echo "[$rev] arm exited rc=$rc after $((SECONDS - start))s"
else echo "[$rev] arm STILL ALIVE after 30s -> HANG (would stall CI shard)"; fi
if kill -0 "$watcher" 2>/dev/null; then echo "[$rev] watcher pid $watcher still alive"; else echo "[$rev] watcher pid $watcher gone"; fi
echo "[$rev] arm stderr:"; sed 's/^/    /' "$work/$rev/arm.err"
# cleanup
kill -KILL "$arm" "$watcher" 2>/dev/null; wait 2>/dev/null
