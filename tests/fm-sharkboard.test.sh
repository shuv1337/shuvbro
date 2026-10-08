#!/usr/bin/env bash
# Exercise SHark transport with a fake scoped server and the real locked intake.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi not found'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-sharkboard)
trap fm_test_cleanup EXIT
export FM_HOME="$TMP_ROOT/home" FM_SHARKBOARD_CONFIG="$TMP_ROOT/token.json"
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config" "$TMP_ROOT/fakebin"
printf '{}\n' > "$FM_SHARKBOARD_CONFIG"
chmod 600 "$FM_SHARKBOARD_CONFIG"
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
cat > "$FM_HOME/data/backlog.md" <<'DATA'
## In flight

## Queued
- [ ] bridge-test - Test captain decision (repo: sample) (kind: ship) (since 2026-10-01)

## Done
DATA
export FAKE_SHARK_STATE="$TMP_ROOT/server.json"
cat > "$TMP_ROOT/fakebin/sharkctl" <<'JS'
#!/usr/bin/env node
const fs = require('fs');
const a = process.argv.slice(2), verb = a[1];
const file = process.env.FAKE_SHARK_STATE;
const s = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : { asks: {}, events: [], calls: [] };
const key = a[a.indexOf('--key') + 1];
const body = a.includes('--stdin') ? JSON.parse(fs.readFileSync(0, 'utf8')) : {};
s.calls.push({verb, key, body});
let out = {};
if (verb === 'ask') {
  s.asks[key] ??= { ...body, id: `ask-${Object.keys(s.asks).length}`, revision: 1, status: 'open' };
  out = {ask: s.asks[key]};
}
if (verb === 'get') out = {ask: s.asks[key]};
if (verb === 'answers') out = {events: s.events, cursor: 'cursor'};
if (verb === 'ack') s.acked = (s.acked ?? 0) + 1;
if (verb === 'cancel') s.asks[key].status = 'cancelled';
fs.writeFileSync(file, JSON.stringify(s));
console.log(JSON.stringify(out));
JS
chmod +x "$TMP_ROOT/fakebin/sharkctl"
export PATH="$TMP_ROOT/fakebin:$PATH"
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Proceed with fixture?' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" publish
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")" = 1 ] || fail 'unchanged ask republished'
jq '.events = [(.asks|to_entries[0]|{eventId:"event-1",askKey:.key,askId:.value.id,revision:1,status:"answered",waitingTaskId:"bridge-test",optionId:"no",text:null,answeredVia:"web"})]' "$FAKE_SHARK_STATE" > "$TMP_ROOT/update"
mv "$TMP_ROOT/update" "$FAKE_SHARK_STATE"
"$ROOT/bin/fm-sharkboard.sh" answers
"$ROOT/bin/fm-sharkboard.sh" answers
[ "$(jq '.acked' "$FAKE_SHARK_STATE")" = 1 ] || fail 'answer ack replayed'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'No released the held work'
"$ROOT/bin/fm-board.sh" model > "$TMP_ROOT/model"
[ "$(jq '.with_lead|length' "$TMP_ROOT/model")" = 1 ] || fail 'No did not reach keyed intake'
FM_TASK_ID=worker "$ROOT/bin/fm-sharkboard.sh" sync > /dev/null 2>&1 && fail 'worker adapter accepted' || true
pass 'changed-row publication, scoped answer intake, No hold preservation, replay and worker guard'
# A new lifecycle must not accept the old revision, even if its title is unchanged.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'A different question' >/dev/null
jq '.events[0].eventId="old-race" | .events[0].optionId="yes"' "$FAKE_SHARK_STATE" > "$TMP_ROOT/update"
mv "$TMP_ROOT/update" "$FAKE_SHARK_STATE"
"$ROOT/bin/fm-sharkboard.sh" answers
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'old answer released new hold'
[ "$(jq '.events["old-race"]' "$FM_HOME/state/sharkboard/last.json")" = '"stale"' ] || fail 'old answer not classified stale'
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq '[.asks[]]|length' "$FAKE_SHARK_STATE")" = 2 ] || fail 'new lifecycle reused old remote ask'
# Simulate a process lost during intake. Never acknowledge an uncertain outcome.
jq '.events[0].eventId="interrupted"' "$FAKE_SHARK_STATE" > "$TMP_ROOT/update"
mv "$TMP_ROOT/update" "$FAKE_SHARK_STATE"
jq '.events.interrupted="applying"' "$FM_HOME/state/sharkboard/last.json" > "$TMP_ROOT/update"
mv "$TMP_ROOT/update" "$FM_HOME/state/sharkboard/last.json"
# Bind event to the remaining current ask to test the recovery boundary.
jq '.events=[(.asks|to_entries|map(select(.value.status=="open"))[0]|{eventId:"interrupted",askKey:.key,askId:.value.id,revision:1,status:"answered",waitingTaskId:"bridge-test",optionId:"yes",answeredVia:"web"})]' "$FAKE_SHARK_STATE" > "$TMP_ROOT/update"
mv "$TMP_ROOT/update" "$FAKE_SHARK_STATE"
if "$ROOT/bin/fm-sharkboard.sh" answers > /dev/null 2>&1; then fail 'uncertain answer replayed'; fi
[ "$(jq '.acked' "$FAKE_SHARK_STATE")" = 1 ] || fail 'uncertain answer acknowledged'
pass 'new lifecycle rejects stale approval and interrupted receipt fails closed'
