#!/usr/bin/env bash
# scen.sh <inst-dir> <label>
set -u
ROOT=$1; LABEL=$2; W=$HOME/.cache/agent-ws/board-live/$LABEL-home
rm -rf "$W"; mkdir -p "$W/data" "$W/state" "$W/config" "$W/projects" "$W/fakebin"
cp "$ROOT/.tasks.toml" "$W/.tasks.toml"
cat > "$W/data/backlog.md" <<'B'
## In flight

## Queued
- [ ] sample-ship - Ship the sample widget (repo: sample) (kind: ship) (since 2026-07-01)
- [ ] sample-plain - Plain queued work (repo: sample) (kind: ship) (since 2026-07-01)

## Done
B
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/$t"; chmod +x "$W/fakebin/$t"; done
export PATH="$W/fakebin:$PATH" FM_HOME="$W" FM_STATE_OVERRIDE="$W/state" FM_DATA_OVERRIDE="$W/data" FM_CONFIG_OVERRIDE="$W/config"
: > "$W/model-calls.log"
(cd "$W" && FM_BOARD_PORT=0 FM_BOARD_INTERVAL=10 exec "$ROOT/bin/fm-board.sh" serve) > "$W/serve.log" 2>&1 &
PID=$!; echo $PID > "$W/pid"
for i in $(seq 300); do [ -s "$W/state/board/serve.json" ] && break; sleep 0.1; done
PORT=$(jq -r .port "$W/state/board/serve.json"); echo $PORT > "$W/port"
calls() { wc -l < "$W/model-calls.log" | tr -d ' '; }
cpu() { awk '{print $14+$15+$16+$17}' /proc/$PID/stat; }
data() { curl -s "http://127.0.0.1:$PORT/board.json"; }
say() { echo "[$LABEL] $*"; }
say "started on 127.0.0.1:$PORT; model rebuilds so far: $(calls)"
c0=$(cpu); n0=$(calls); sleep ${IDLE:-60}
say "A idle ${IDLE:-60}s with no client: model rebuilds=$(( $(calls)-n0 )), CPU ticks=$(( $(cpu)-c0 ))"
[ "$LABEL" = base ] && { kill $PID; exit 0; }
# B: change backlog while idle, then open
sed -i 's/^## Done/- [ ] while-idle - Added while nobody looked (repo: sample) (kind: ship) (since 2026-07-02)\n\n## Done/' "$W/data/backlog.md"
n0=$(calls); d=$(data)
say "B open after idle: rebuilds on open=$(( $(calls)-n0 )); 'while-idle' visible=$(printf '%s' "$d" | jq '[.. | strings | select(test("Added while nobody looked"))] | length > 0'); snapshot=$(printf '%s' "$d" | jq -r .snapshot_generated)"
# C: unchanged polling
n0=$(calls); c0=$(cpu); snaps=""
for i in $(seq 10); do snaps+="$(data | jq -r '.snapshot_generated + " age=" + (.age_seconds|tostring)')"$'\n'; sleep 2; done
say "C 10 checks every 2s, unchanged: rebuilds=$(( $(calls)-n0 )), CPU ticks=$(( $(cpu)-c0 )), distinct snapshots=$(printf '%s' "$snaps" | cut -d' ' -f1 | sort -u | grep -c .)"
# D: status log change
n0=$(calls); echo "$(date -u +%FT%TZ) working: live test" >> "$W/state/sample-ship.status"; data >/dev/null
say "D status log appended -> rebuilds on next check=$(( $(calls)-n0 ))"
# G: concurrent burst, unchanged then changed
n0=$(calls); pids=(); for i in $(seq 20); do data >/dev/null & pids+=($!); done; wait "${pids[@]}"
say "G1 20 concurrent checks, unchanged: rebuilds=$(( $(calls)-n0 ))"
n0=$(calls); printf "[]\n" > "$W/data/board-notes.json"; pids=(); for i in $(seq 20); do data >/dev/null & pids+=($!); done; wait "${pids[@]}"
say "G2 20 concurrent checks after notes file appears: rebuilds=$(( $(calls)-n0 ))"
# E: hold then answer
"$ROOT/bin/fm-captain-hold.sh" hold sample-ship --reason "Ship the sample widget now?" >/dev/null || say "hold failed"
n0=$(calls); d=$(data)
card=$(printf '%s' "$d" | jq -r '.waiting_on_you[] | select(.id=="sample-ship" and .answerable) | .card')
say "E1 after captain hold: rebuilds=$(( $(calls)-n0 )); sample-ship waiting & answerable=$([ -n "$card" ] && echo true || echo false)"
TOKEN=$(curl -s "http://127.0.0.1:$PORT/" | sed -n 's/.*name="fm-board-token" content="\([0-9a-f]*\)".*/\1/p' | head -1)
n0=$(calls)
body=$(jq -cn --arg t "$TOKEN" --arg c "$card" '{token:$t, task:"sample-ship", card:$c, choice:"no"}')
resp=$(curl -s -w '\nHTTP %{http_code}' -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$PORT" -d "$body" "http://127.0.0.1:$PORT/answer")
say "E2 answer 'no' response: $(printf '%s' "$resp" | tr '\n' ' ' | cut -c1-300)"
d=$(data)
say "E3 after answer: rebuilds since answer=$(( $(calls)-n0 )); sample-ship still answerable=$(printf '%s' "$d" | jq 'any(.waiting_on_you[]; .id=="sample-ship" and .answerable)')"
# F: real 60s full bound with unchanged records
n0=$(calls); start=$(date +%s); first=""
while [ $(( $(date +%s)-start )) -lt 75 ]; do data >/dev/null; [ -z "$first" ] && [ $(calls) -gt $n0 ] && first=$(( $(date +%s)-start )); sleep 5; done
say "F 75s of checks every 5s, unchanged: rebuilds=$(( $(calls)-n0 )); first forced rebuild at ~${first:-none}s after start of window"
kill $PID
