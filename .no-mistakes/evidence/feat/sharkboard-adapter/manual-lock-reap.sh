#!/usr/bin/env bash
# Manual drive of bin/fm-sharkboard.sh publish against an isolated FM_HOME and fixture fake sharkctl.
set -u
ROOT=$1 W=$2
export PATH="$W/bin:$PATH" FM_HOME="$W/home" FM_SHARKBOARD_CONFIG="$W/token.json" FAKE_SHARK_STATE="$W/server.json" FAKE_SHARK_FAIL="$W/fail"
unset HARK_TOKEN HARK_API_URL; export HARK_CONFIG="$FM_SHARKBOARD_CONFIG"
mkdir -p "$FM_HOME/data" "$FM_HOME/state/sharkboard" "$FM_HOME/config"
printf '{}\n' > "$FM_SHARKBOARD_CONFIG"; chmod 600 "$FM_SHARKBOARD_CONFIG"
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n- [ ] demo - Demo queued work (repo: sample) (kind: ship) (since 2026-10-01)\n\n## Done\n' > "$FM_HOME/data/backlog.md"
S="$FM_HOME/state/sharkboard"
sleep 0 & dead=$!; wait $dead
run() { echo "\$ fm-sharkboard.sh publish   # $1"; "$ROOT/bin/fm-sharkboard.sh" publish; echo "exit=$?"; echo "state/sharkboard: $(cd "$S" && ls -d lock* 2>/dev/null | tr '\n' ' ')"; [ -f "$S/lock/owner" ] && echo "lock/owner=$(cat "$S/lock/owner")"; echo; }
echo "== 1. dead main-lock owner + legacy OWNERLESS lock.reap (pre-2d9f63b mkdir) =="
mkdir "$S/lock" "$S/lock.reap"; printf '{"pid":%s,"start":"1"}' "$dead" > "$S/lock/owner"
run "ownerless lock.reap must be refused, nothing removed"
echo "== 2. operator reconciles manually (removes ownerless reap) and retries =="
rm -r "$S/lock.reap"
run "dead main owner now reaped; publish proceeds"
echo "sharkctl verbs sent: $(jq -r '[.calls[].verb]|join(",")' "$FAKE_SHARK_STATE")"
echo; echo "== 3. legacy OWNERLESS main lock (empty dir) =="
mkdir "$S/lock"
run "ownerless main lock must be refused, not overwritten"
rm -r "$S/lock"
echo "== 4. live owner on main lock =="
sleep 30 & live=$!
printf '{"pid":%s,"start":"%s"}' "$live" "$(awk '{print $22}' /proc/$live/stat)" > /dev/null
mkdir "$S/lock"; node -e "const fs=require('fs');const st=fs.readFileSync('/proc/$live/stat','utf8').split(') ')[1].split(' ')[19];fs.writeFileSync('$S/lock/owner',JSON.stringify({pid:$live,start:st}))"
run "live owner retained"
kill $live; rm -r "$S/lock"
