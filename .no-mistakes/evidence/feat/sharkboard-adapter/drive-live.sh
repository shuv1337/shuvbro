#!/usr/bin/env bash
# drive.sh <ROOT> <workdir> : drive real fm-sharkboard + real sharkctl against loopback emulator
set -u
ROOT=$1 W=$2; rm -rf "$W"; mkdir -p "$W"
export FM_HOME="$W/home" FM_SHARKBOARD_CONFIG="$W/token.json"
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config"
TOK=hark_$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 43)
printf '{"token":"%s","apiUrl":"http://127.0.0.1:47811/"}\n' "$TOK" > "$FM_SHARKBOARD_CONFIG"; chmod 600 "$FM_SHARKBOARD_CONFIG"
DECOY=hark_$(printf 'd%.0s' $(seq 43))
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
cat > "$FM_HOME/data/backlog.md" <<'DATA'
## In flight
- [ ] live-flight - Exercise in-flight heartbeat (repo: sample) (kind: ship) (since 2026-10-01)

## Queued
- [ ] live-hold - Live captain decision (repo: sample) (kind: ship) (since 2026-10-01)

## Done
DATA
node emu.mjs 47811 "$W/real.log" "$TOK" "$W/events.json" & E1=$!
node emu.mjs 47812 "$W/decoy.log" "$DECOY" "$W/events.json" & E2=$!
trap 'kill $E1 $E2 2>/dev/null' EXIT; sleep 0.5
export HARK_TOKEN=$DECOY HARK_API_URL=http://127.0.0.1:47812
step() { echo; echo "\$ $*"; "$@"; echo "[exit $?]"; }
step "$ROOT/bin/fm-captain-hold.sh" hold live-hold --reason 'Ship the live fixture?'
step "$ROOT/bin/fm-sharkboard.sh" publish
step "$ROOT/bin/fm-sharkboard.sh" publish
echo; echo "== requests reaching the dedicated config origin (port 47811):"; jq -c '{method,path,auth,key:(.body.key),title:(.body.title),state:(.body.state),push:(.body.push),taskId:(.body.taskId)}' "$W/real.log" 2>/dev/null
echo "== requests reaching the ambient HARK_API_URL decoy (port 47812):"; cat "$W/decoy.log" 2>/dev/null || echo "(none)"
ASK=$(curl -s -H "authorization: Bearer $TOK" http://127.0.0.1:47811/api/agent/board/state | jq -c '.asks|to_entries[0]|{key:.key,id:.value.id,revision:.value.revision}')
echo "== open ask: $ASK"
[ -n "$ASK" ] && [ "$ASK" != null ] || exit 0
echo "$ASK" | jq -c '[{eventId:"live-ev-1",askKey:.key,askId:.id,revision:.revision,status:"answered",waitingTaskId:"live-hold",optionId:null,text:"Not yet - wait for the review",answeredVia:"web"}]' > "$W/events.json"
echo "== captain free-text reply injected into answer feed"
step "$ROOT/bin/fm-sharkboard.sh" sync
step "$ROOT/bin/fm-sharkboard.sh" sync
echo "== hold still open after free text?"; "$ROOT/bin/fm-captain-hold.sh" open live-hold && echo "yes, held"
echo "== ack calls:"; jq -c 'select(.path|test("/ack$"))|{method,path,auth}' "$W/real.log"
echo "== receipts:"; jq -c '.events' "$FM_HOME/state/sharkboard/last.json"
echo "== decoy requests total: $( [ -f "$W/decoy.log" ] && wc -l < "$W/decoy.log" || echo 0)"
echo "== worker refused:"; FM_TASK_ID=worker-x "$ROOT/bin/fm-sharkboard.sh" sync; echo "[exit $?]"
