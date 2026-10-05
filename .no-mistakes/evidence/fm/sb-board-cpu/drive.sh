#!/usr/bin/env bash
# drive.sh <root> <label> <idle-seconds>
set -u
ROOT=$1 LABEL=$2 IDLE=$3
H=/tmp/fmboard-live/home-$LABEL
rm -rf "$H"; mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
cat > "$H/data/backlog.md" <<'B'
## In flight

## Queued
- [ ] sample-ship - Ship the sample widget (repo: sample) (kind: ship) (since 2026-07-01)
- [ ] sample-plain - Plain queued work (repo: sample) (kind: ship) (since 2026-07-01)

## Done
B
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
envs=(PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_BOARD_PORT=0)
(cd "$H" && exec env "${envs[@]}" "$ROOT/bin/fm-board.sh" serve) > "$H/serve.log" 2>&1 &
i=0; while [ ! -s "$H/state/board/serve.json" ]; do i=$((i+1)); [ $i -le 300 ] || { echo "no start"; cat "$H/serve.log"; exit 1; }; sleep 0.1; done
PID=$(jq -r .pid "$H/state/board/serve.json"); PORT=$(jq -r .port "$H/state/board/serve.json")
TCK=$(getconf CLK_TCK)
cpu() { awk -v t=$TCK '{printf "%.2f", ($14+$15+$16+$17)/t}' /proc/$PID/stat; }
echo "[$LABEL] serving pid=$PID port=$PORT (FM_BOARD_INTERVAL default 10s)"
sleep 1; c0=$(cpu)
echo "[$LABEL] idle ${IDLE}s with no client connected..."
sleep "$IDLE"; c1=$(cpu)
echo "[$LABEL] CPU (server+children) during idle ${IDLE}s: $(awk -v a=$c0 -v b=$c1 'BEGIN{printf "%.2fs", b-a}')"
echo "$LABEL $(awk -v a=$c0 -v b=$c1 'BEGIN{printf "%.2f", b-a}')" >> /tmp/fmboard-live/idle-cpu.txt
data() { curl -s -H "Host: 127.0.0.1:$PORT" "http://127.0.0.1:$PORT/board.json"; }
t0=$(date +%s.%N); d1=$(data); t1=$(date +%s.%N)
echo "[$LABEL] first /data after idle: $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2fs", b-a}') snapshot_generated=$(jq -r .snapshot_generated <<<"$d1") generated=$(jq -r .generated <<<"$d1") age=$(jq -r .age_seconds <<<"$d1") queued=$(jq -c '[.queued[]?.id]' <<<"$d1")"
echo "$d1" | jq . > /tmp/fmboard-live/$LABEL-data1.json
if [ "${4:-}" = full ]; then
  sleep 3; c2=$(cpu); t0=$(date +%s.%N); d2=$(data); t1=$(date +%s.%N); c3=$(cpu)
  echo "[$LABEL] unchanged re-check after 3s: $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.3fs", b-a}') cpu=$(awk -v a=$c2 -v b=$c3 'BEGIN{printf "%.2fs", b-a}') snapshot_generated=$(jq -r .snapshot_generated <<<"$d2") generated=$(jq -r .generated <<<"$d2") age=$(jq -r .age_seconds <<<"$d2")"
  sed -i 's/^- \[ \] sample-plain - Plain queued work/- [ ] sample-plain - Plain queued work\n- [ ] sample-new - Newly queued while page open/' "$H/data/backlog.md"
  d3=$(data)
  echo "[$LABEL] after editing backlog.md: snapshot_generated=$(jq -r .snapshot_generated <<<"$d3") queued=$(jq -c '[.queued[]?.id]' <<<"$d3")"
  echo "$d3" | jq . > /tmp/fmboard-live/$LABEL-data3.json
  echo "[$LABEL] waiting 62s with page polling every 10s (unchanged records) ..."
  snaps=()
  for k in 1 2 3 4 5 6 7; do sleep 9; s=$(data | jq -r .snapshot_generated); snaps+=("$s"); done
  printf '[%s] polled snapshot_generated: %s\n' "$LABEL" "${snaps[*]}"
fi
kill $PID; wait 2>/dev/null
