#!/usr/bin/env bash
# Hand-driven transcript of the real fm-sharkboard.sh CLI + real fm-captain-hold/fm-board
# in an isolated FM_HOME; SHark is replaced by the contract fake sharkctl from tests/fm-sharkboard.test.sh.
set -u
ROOT=$1 W=$2
export FM_HOME=$W/home FM_SHARKBOARD_CONFIG=$W/token.json FAKE_SHARK_STATE=$W/server.json FAKE_SHARK_FAIL=$W/fail PATH=$W/fakebin:$PATH
mkdir -p $FM_HOME/data $FM_HOME/state $FM_HOME/config; printf '{}\n' > $FM_SHARKBOARD_CONFIG; chmod 600 $FM_SHARKBOARD_CONFIG
cp $ROOT/.tasks.toml $FM_HOME/.tasks.toml
printf '## In flight\n\n## Queued\n- [ ] demo - Demo captain decision (repo: sample) (kind: ship) (since 2026-10-01)\n\n## Done\n' > $FM_HOME/data/backlog.md
S=$FM_HOME/state/sharkboard/last.json
run(){ echo "\$ $*"; "$@"; echo "[exit $?]"; }
key(){ jq -r '[.rows|to_entries[]|select(.value.type=="ask" and .value.card)]|last|.key' $S; }
srv(){ jq -c --arg k "$(key)" '.asks[$k]|{id,revision,status,snoozeUntil,acked}' $FAKE_SHARK_STATE; }
echo "== 1. publish a held question with ambient HARK_* set (must be ignored), then republish unchanged"
run $ROOT/bin/fm-captain-hold.sh hold demo --reason 'Ship demo?'
HARK_TOKEN=ambient HARK_API_URL=https://wrong.invalid run $ROOT/bin/fm-sharkboard.sh publish
run $ROOT/bin/fm-sharkboard.sh publish
echo "ask puts: $(jq '[.calls[]|select(.verb=="ask")]|length' $FAKE_SHARK_STATE)  push flags: $(jq -c '[.calls[]|select(.verb=="ask")|.body.push]' $FAKE_SHARK_STATE)"
echo "remote ask: $(srv)"
echo; echo "== 2. captain dismisses on phone; ack response is lost once; next sync acks and reasserts the still-local hold"
k=$(key); old=$(jq -r --arg k $k '.asks[$k].id' $FAKE_SHARK_STATE)
jq --arg k $k '.asks[$k] as $a|.events=[{eventId:"dismiss-1",askKey:$k,askId:$a.id,revision:$a.revision,status:"cancelled",waitingTaskId:"demo",answeredVia:"ios_app"}]|.asks[$k].status="cancelled"' $FAKE_SHARK_STATE > $W/u && mv $W/u $FAKE_SHARK_STATE
echo ack-lost > $FAKE_SHARK_FAIL; run $ROOT/bin/fm-sharkboard.sh sync; rm $FAKE_SHARK_FAIL
echo "receipt after lost ack: $(jq -r '.events["dismiss-1"]' $S)"
run $ROOT/bin/fm-sharkboard.sh sync
echo "receipt: $(jq -r '.events["dismiss-1"]' $S); old ask $old -> remote now $(srv)"
run $ROOT/bin/fm-captain-hold.sh open demo
echo "lead inbox note:"; grep -h -i -A2 dismiss $FM_HOME/state/inbox/*.note | head -6
echo; echo "== 3. captain picks Later 400 days out (bad_date > 366d): rejected, card unsnoozed, hold kept"
k=$(key); far=$(node -e 'console.log(new Date(Date.now()+400*86400000).toISOString())')
jq --arg k $k --arg u $far '.asks[$k].snoozeUntil=$u|.events=[]' $FAKE_SHARK_STATE > $W/u && mv $W/u $FAKE_SHARK_STATE
echo "before: $(srv)"; run $ROOT/bin/fm-sharkboard.sh sync; echo "after:  $(srv)"
echo "snooze receipts: $(jq -c '.events|with_entries(select(.key|test("snooze")))' $S)"
run $ROOT/bin/fm-captain-hold.sh open demo
echo; echo "== 4. Later 3 days out is applied as a dated hold, not acked, ask cancelled"
k=$(key); near=$(node -e 'console.log(new Date(Date.now()+3*86400000).toISOString())')
jq --arg k $k --arg u $near '.asks[$k].snoozeUntil=$u|.events=[]' $FAKE_SHARK_STATE > $W/u && mv $W/u $FAKE_SHARK_STATE
a0=$(jq .acked $FAKE_SHARK_STATE); run $ROOT/bin/fm-sharkboard.sh sync
echo "acks unchanged: $a0 -> $(jq .acked $FAKE_SHARK_STATE); remote $(jq -c --arg k $k '.asks[$k]|{status}' $FAKE_SHARK_STATE)"
grep -h 'deferred until' $FM_HOME/state/inbox/*.note | tail -1
echo; echo "== 5. abandoned recovery mutex with dead owner record is recovered; live owner kept; ownerless legacy refused"
L=$FM_HOME/state/sharkboard; sh -c 'exit 0' & d=$!; wait $d
mkdir $L/lock $L/lock.reap; printf '{"pid":%s,"start":"1"}' $d > $L/lock/owner
printf '{"pid":%s,"start":"%s"}' $$ "$(sed 's/.*) //' /proc/$$/stat | cut -d' ' -f20)" > $L/lock.reap/owner
echo "-- live reaper owner"; run $ROOT/bin/fm-sharkboard.sh publish; ls $L/lock.reap
printf '{"pid":%s,"start":"1"}' $d > $L/lock.reap/owner
echo "-- dead reaper owner"; run $ROOT/bin/fm-sharkboard.sh publish; ls -d $L/lock $L/lock.reap 2>&1
mkdir $L/lock $L/lock.reap; printf '{"pid":%s,"start":"1"}' $d > $L/lock/owner
echo "-- ownerless legacy lock.reap"; run $ROOT/bin/fm-sharkboard.sh publish; ls -d $L/lock.reap
rm -r $L/lock $L/lock.reap
echo; echo "== 6. task worker cannot drive the board"
FM_TASK_ID=worker run $ROOT/bin/fm-sharkboard.sh sync
