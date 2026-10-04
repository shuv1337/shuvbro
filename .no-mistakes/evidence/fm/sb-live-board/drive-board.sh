#!/usr/bin/env bash
# Live drive: disposable home, real fm-board.sh serve, real headless Chromium clicks.
set -eu
ROOT=/home/shuv/.no-mistakes/worktrees/8a7692f99431/01M42XTSXN3AWTYHEECKTMPNXQ
E=/home/shuv/.no-mistakes/evidence/01M42XTSXN3AWTYHEECKTMPNXQ
H=$(mktemp -d ~/.cache/agent-ws/board-live.XXXX)
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
cat > "$H/data/backlog.md" <<'B'
## In flight

## Queued
- [ ] sample-ship - Ship the sample widget (repo: sample) (kind: ship) (since 2026-07-01)
- [ ] sample-plain - Plain queued work (repo: sample) (kind: ship) (since 2026-07-01)

## Done
B
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
envh() { PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$@"; }
cd "$H"
envh "$ROOT/bin/fm-captain-hold.sh" hold call-yes --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes" >/dev/null
envh "$ROOT/bin/fm-captain-hold.sh" hold sample-ship --reason "Merge PR 5 now? Recommend yes" >/dev/null
envh "$ROOT/bin/fm-captain-hold.sh" hold sample-plain --reason "Land the plain work now? Recommend yes" >/dev/null
envh "$ROOT/bin/fm-captain-hold.sh" hold call-option --title "Pick a rollout" --reason "Staged or all at once?" --option Staged --option "All at once" >/dev/null
envh env FM_BOARD_PORT=0 FM_BOARD_INTERVAL=2 "$ROOT/bin/fm-board.sh" serve > "$H/serve.log" 2>&1 &
BPID=$!
trap 'kill $BPID 2>/dev/null; kill $CPID 2>/dev/null; true' EXIT
for i in $(seq 100); do [ -s "$H/state/board/serve.json" ] && break; sleep 0.1; done
PORT=$(jq -r .port "$H/state/board/serve.json")
echo "board on 127.0.0.1:$PORT  home=$H"
envh "$ROOT/bin/fm-board.sh" status || true
unset DISPLAY
chromium --headless=new --remote-debugging-port=9333 --user-data-dir="$H/chrome" --window-size=1100,1400 about:blank >/dev/null 2>&1 &
CPID=$!
sleep 2
node "$E/cdp-drive.mjs" "$PORT" "$E"
SAVE_PORT=$PORT
echo "--- task records after browser clicks ---"
for id in call-yes sample-ship sample-plain call-option; do echo "## $id"; tasks-axi show $id --full | grep -E "state:|held:|Answer:|Captain answer recorded" ; done
echo "--- merge guard: sample-ship (answered No) still held ---"
envh "$ROOT/bin/fm-captain-hold.sh" status sample-ship 2>&1 | head -5 || true
echo "--- inbox notes ---"; ls "$H/state/inbox" | wc -l; cat "$H"/state/inbox/*.note | grep -h "Live board answer" || true
echo "--- stop the board server, watch the open page go stale ---"
kill $BPID; wait $BPID 2>/dev/null || true
node "$E/cdp-drive.mjs" "$PORT" "$E" stale
echo "HOME=$H"
