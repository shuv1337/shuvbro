#!/usr/bin/env bash
# Manual operator session: drives bin/fm-sharkboard.sh (real bridge, real fm-board/hold/inbox)
# in an isolated FM_HOME against the fixture SHark server copied from tests/fm-sharkboard.test.sh.
set -u
ROOT=$1 W=$2
export FM_HOME="$W/home" FM_SHARKBOARD_CONFIG="$W/token.json" FAKE_SHARK_STATE="$W/server.json" FAKE_SHARK_FAIL="$W/fail"
export PATH="$W/fakebin:$PATH"
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config"
printf '{}\n' > "$FM_SHARKBOARD_CONFIG"; chmod 600 "$FM_SHARKBOARD_CONFIG"
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
cat > "$FM_HOME/data/backlog.md" <<'DATA'
## In flight

## Queued
- [ ] task-a - Captain decision A (repo: sample) (kind: ship) (since 2026-10-01)
- [ ] task-b - Captain decision B (repo: sample) (kind: ship) (since 2026-10-01)

## Done
DATA
S="$FM_HOME/state/sharkboard/last.json"
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; }
echo '== 1. Lead holds two tasks and publishes (ambient HARK_TOKEN/HARK_API_URL set; must be ignored)'
"$ROOT/bin/fm-captain-hold.sh" hold task-a --reason 'Ship A now?' >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold task-b --reason 'Ship B now?' >/dev/null
echo "\$ HARK_TOKEN=x HARK_API_URL=https://wrong.invalid fm-sharkboard.sh publish"
HARK_TOKEN=x HARK_API_URL=https://wrong.invalid "$ROOT/bin/fm-sharkboard.sh" publish; echo "[exit $?]"
run "$ROOT/bin/fm-sharkboard.sh" publish
echo "ask calls sent to SHark: $(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")  (expect 2; unchanged second publish sends none)"
echo "ask push/scope sample: $(jq -c '[.calls[]|select(.verb=="ask")][0].body|{title,taskId,push,waitingTaskId}' "$FAKE_SHARK_STATE")"
KA=$(jq -r '.asks|to_entries[]|select(.value.title|test("A"))|.key' "$FAKE_SHARK_STATE"); KB=$(jq -r '.asks|to_entries[]|select(.value.title|test("B"))|.key' "$FAKE_SHARK_STATE")
echo
echo '== 2. Captain answers B with free text; then an interrupted intake on A (applying journal, process lost)'
IDA=$(jq -r --arg k "$KA" '.asks[$k].id' "$FAKE_SHARK_STATE"); IDB=$(jq -r --arg k "$KB" '.asks[$k].id' "$FAKE_SHARK_STATE")
jq --arg ka "$KA" --arg kb "$KB" --arg ia "$IDA" --arg ib "$IDB" '.events=[{eventId:"ev-b",askKey:$kb,askId:$ib,revision:1,status:"answered",waitingTaskId:"task-b",optionId:null,text:"Hold until Monday please",answeredVia:"ios_app"},{eventId:"ev-a",askKey:$ka,askId:$ia,revision:1,status:"answered",waitingTaskId:"task-a",optionId:"yes",answeredVia:"ios_app"}] | .asks[$ka].status="answered" | .asks[$kb].status="answered"' "$FAKE_SHARK_STATE" > "$W/u" && mv "$W/u" "$FAKE_SHARK_STATE"
jq --arg ka "$KA" '.rows[$ka] as $r | .events["ev-a"]="applying" | .intakes["ev-a"]={key:$ka,event:{eventId:"ev-a",askKey:$ka,askId:$r.askId,revision:$r.revision,status:"answered",optionId:"yes",answeredVia:"ios_app",waitingTaskId:"task-a"}}' "$S" > "$W/u" && mv "$W/u" "$S"
run "$ROOT/bin/fm-sharkboard.sh" sync
echo "receipts: $(jq -c '.events' "$S")"
echo "acks on SHark: $(jq '.acked // 0' "$FAKE_SHARK_STATE")  (expect 1: B's free text acked once, A never)"
echo "task-b still held (free text keeps work held): $("$ROOT/bin/fm-captain-hold.sh" open task-b >/dev/null && echo yes || echo no)"
echo "task-a still held (uncertain, no replay): $("$ROOT/bin/fm-captain-hold.sh" open task-a >/dev/null && echo yes || echo no)"
echo "inbox notes to lead:"; for f in "$FM_HOME"/state/inbox/*.note; do echo "--- $(basename "$f")"; head -4 "$f"; done
echo
echo '== 3. Lead changes task-a question while quarantined; repeated syncs must not republish it nor replay intake'
"$ROOT/bin/fm-captain-hold.sh" hold task-a --reason 'Changed A question' >/dev/null
before=$(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")
run "$ROOT/bin/fm-sharkboard.sh" sync; run "$ROOT/bin/fm-sharkboard.sh" sync
echo "ask calls before/after: $before/$(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")  (expect equal)"
echo
echo '== 4. Operator inspects quarantines'
run "$ROOT/bin/fm-sharkboard.sh" quarantines
echo
echo '== 5. Adversarial reconcile: wrong receipt, missing outcome'
run "$ROOT/bin/fm-sharkboard.sh" reconcile --key "$KA" --receipt bogus --outcome recorded
run "$ROOT/bin/fm-sharkboard.sh" reconcile --key "$KA" --receipt ev-a
echo
echo '== 6. Explicit reconcile (recorded), repeated for idempotency, then sync publishes replacement'
run "$ROOT/bin/fm-sharkboard.sh" reconcile --key "$KA" --receipt ev-a --outcome recorded
run "$ROOT/bin/fm-sharkboard.sh" reconcile --key "$KA" --receipt ev-a --outcome recorded
run "$ROOT/bin/fm-sharkboard.sh" sync
echo "receipt ev-a: $(jq -r '.events["ev-a"]' "$S")  acks: $(jq '.acked' "$FAKE_SHARK_STATE")  ask calls: $(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")"
echo "latest replacement ask title: $(jq -r '[.calls[]|select(.verb=="ask")]|last|.body.title' "$FAKE_SHARK_STATE")"
echo "task-a still held after reconcile (reconcile never invokes intake): $("$ROOT/bin/fm-captain-hold.sh" open task-a >/dev/null && echo yes || echo no)"
echo
echo '== 7. Worker cannot drive the bridge'
echo "\$ FM_TASK_ID=worker fm-sharkboard.sh sync"; FM_TASK_ID=worker "$ROOT/bin/fm-sharkboard.sh" sync; echo "[exit $?]"
