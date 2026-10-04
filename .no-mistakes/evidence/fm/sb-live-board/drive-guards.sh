#!/usr/bin/env bash
set -u
ROOT=/home/shuv/.no-mistakes/worktrees/8a7692f99431/01M42XTSXN3AWTYHEECKTMPNXQ
E=/home/shuv/.no-mistakes/evidence/01M42XTSXN3AWTYHEECKTMPNXQ
H=$(mktemp -d ~/.cache/agent-ws/board-guard.XXXX)
mkdir -p "$H/data" "$H/state" "$H/config" "$H/fakebin"; cp "$ROOT/.tasks.toml" "$H/"
printf '## In flight\n\n## Queued\n- [ ] sample-ship - Ship the sample widget (repo: sample) (kind: ship) (since 2026-07-01)\n\n## Done\n' > "$H/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
envh() { PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$@"; }
cd "$H"
envh "$ROOT/bin/fm-captain-hold.sh" hold call-a --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes" >/dev/null
envh "$ROOT/bin/fm-captain-hold.sh" hold sample-ship --reason "Merge PR 5 now? Recommend yes" >/dev/null
( PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_BOARD_PORT=0 FM_BOARD_INTERVAL=60 exec "$ROOT/bin/fm-board.sh" serve > "$H/serve.log" 2>&1 ) &
for i in $(seq 100); do [ -s "$H/state/board/serve.json" ] && break; sleep 0.1; done
BPID=$(jq -r .pid "$H/state/board/serve.json"); PORT=$(jq -r .port "$H/state/board/serve.json")
unset DISPLAY; chromium --headless=new --remote-debugging-port=9333 --user-data-dir="$H/chrome" about:blank >/dev/null 2>&1 & CPID=$!
trap 'kill $BPID $CPID 2>/dev/null' EXIT
sleep 2
node "$E/cdp-guard.mjs" "$PORT" "$E" load
echo "--- lead re-asks call-a with a new reason while the page is open (refresh interval 60s) ---"
envh "$ROOT/bin/fm-captain-hold.sh" hold call-a --reason "Close duplicate PR 14 instead? Recommend yes" >/dev/null
node "$E/cdp-guard.mjs" "$PORT" "$E" stale-click
echo "call-a after stale click:"; tasks-axi show call-a --full | grep -E "state:|held:|Answer:" || echo "  (no Answer recorded)"
echo "--- Later from the browser on held work ---"
node "$E/cdp-guard.mjs" "$PORT" "$E" later
tasks-axi show sample-ship --full | grep -E "state:|held:|hold_until|Answer:"
echo "--- cross-origin POST (another site in the browser) ---"
TOKEN=$(curl -s http://127.0.0.1:$PORT/ | sed -n 's/.*name="fm-board-token" content="\([0-9a-f]*\)".*/\1/p' | head -1)
CARD=$(curl -s http://127.0.0.1:$PORT/board.json | jq -r '.waiting_on_you[]|select(.id=="call-a").card')
curl -s -w ' HTTP %{http_code}\n' -X POST -H 'Content-Type: application/json' -H 'Origin: https://evil.example' \
  --data "{\"token\":\"$TOKEN\",\"task\":\"call-a\",\"card\":\"$CARD\",\"choice\":\"yes\"}" http://127.0.0.1:$PORT/answer
echo "--- DNS-rebinding style Host header ---"
curl -s -w ' HTTP %{http_code}\n' -H 'Host: attacker.example' http://127.0.0.1:$PORT/board.json
echo "--- tokenless same-origin POST ---"
curl -s -w ' HTTP %{http_code}\n' -X POST -H 'Content-Type: application/json' -H "Origin: http://127.0.0.1:$PORT" \
  --data "{\"task\":\"call-a\",\"card\":\"$CARD\",\"choice\":\"yes\"}" http://127.0.0.1:$PORT/answer
echo "call-a still held after refused POSTs:"; tasks-axi show call-a --full | grep -E "state:|held:"
echo "inbox notes: $(ls $H/state/inbox 2>/dev/null | wc -l)"
