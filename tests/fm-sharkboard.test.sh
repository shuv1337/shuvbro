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
export FAKE_SHARK_STATE="$TMP_ROOT/server.json" FAKE_SHARK_FAIL="$TMP_ROOT/fail"
cat > "$TMP_ROOT/fakebin/sharkctl" <<'JS'
#!/usr/bin/env node
// Follows SHark's board contract: an upsert opens a new ask once the old one is
// terminal, and every API refusal exits 1 with the server's error on stderr.
const fs = require('fs');
const a = process.argv.slice(2), verb = a[1];
const file = process.env.FAKE_SHARK_STATE;
const s = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : { asks: {}, events: [], calls: [], notes: {}, work: {} };
const fail = fs.existsSync(process.env.FAKE_SHARK_FAIL) ? fs.readFileSync(process.env.FAKE_SHARK_FAIL, 'utf8').trim() : '';
const key = a[a.indexOf('--key') + 1];
const flag = name => a.includes(name) ? a[a.indexOf(name) + 1] : undefined;
const body = a.includes('--stdin') ? JSON.parse(fs.readFileSync(0, 'utf8')) : {};
const save = () => fs.writeFileSync(file, JSON.stringify(s));
const refuse = error => { save(); console.error(error); process.exit(1); };
s.calls.push({verb, key, body, title: flag('--title')});
if (fail === `${verb}-down`) { save(); process.exit(6); }
let out = {}, code = 0;
if (verb === 'ask') {
  const open = s.asks[key]?.status === 'open' ? s.asks[key] : null;
  const content = ({ id, revision, status, snoozeUntil, ...rest }) => JSON.stringify(rest);
  if (!open) s.asks[key] = { ...body, id: `ask-${s.next = (s.next ?? 0) + 1}`, revision: 1, status: 'open' };
  else if (content(open) !== content({ ...body })) s.asks[key] = { ...body, id: open.id, revision: open.revision + 1, status: 'open' };
  out = {ask: s.asks[key]};
}
if (verb === 'get') {
  if (!s.asks[key]) refuse('Ask not found');
  out = {ask: s.asks[key]};
  code = ['expired', 'cancelled'].includes(s.asks[key].status) ? 4 : 0;
}
if (verb === 'cancel') {
  if (s.asks[key]?.status !== 'open') refuse('No open ask with that key');
  s.asks[key].status = 'cancelled';
  out = {ask: s.asks[key]};
}
if (verb === 'answers') out = {events: s.events, cursor: s.cursor ?? 'cursor'};
if (verb === 'ack') s.acked = (s.acked ?? 0) + 1;
if (verb === 'work') s.work[key] = body;
if (verb === 'done') {
  if (!s.work[key] && !flag('--title') && !body.title) refuse('A new done item needs a title');
  s.work[key] = { ...s.work[key], done: flag('--verb') ?? body.verb };
}
if (verb === 'note') {
  if (a.includes('--clear')) { if (!s.notes[key]) refuse('Note not found'); delete s.notes[key]; }
  else s.notes[key] = body;
}
save();
if (fail === `${verb}-lost`) process.exit(1);
console.log(JSON.stringify(out));
process.exit(code);
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
[ "$(jq '.events["old-race"]' "$FM_HOME/state/sharkboard/last.json")" = '"rejected"' ] || fail 'old answer not rejected'
grep -h -A1 -F 'not applied (question changed or no longer waiting)' "$FM_HOME"/state/inbox/*.note | grep -q -F 'Untrusted captain answer: Yes [yes]' \
  || fail 'stale answer was not forwarded with the chosen option'
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
pass 'new lifecycle forwards a stale approval without applying it and interrupted receipt fails closed'

STATE_FILE="$FM_HOME/state/sharkboard/last.json"
update_json() {  # <file> <jq-args>...
  local file=$1; shift
  jq "$@" "$file" > "$TMP_ROOT/update" && mv "$TMP_ROOT/update" "$file"
}
ask_key() { jq -r '[.rows|to_entries[]|select(.value.type=="ask" and .value.card)]|last|.key' "$STATE_FILE"; }
set_events() {  # <key> <event-json-with-eventId>...
  local key=$1 events='[]' extra; shift
  for extra in "$@"; do
    events=$(jq -c --arg key "$key" --argjson extra "$extra" --argjson events "$events" \
      '.asks[$key] as $a | $events + [{askKey:$key,askId:$a.id,revision:$a.revision,status:"answered",waitingTaskId:"bridge-test",answeredVia:"web"} + $extra]' "$FAKE_SHARK_STATE")
  done
  # shellcheck disable=SC2016
  update_json "$FAKE_SHARK_STATE" --arg key "$key" --argjson events "$events" '.events=$events | .asks[$key].status="answered"'
}
receipt() { jq -r --arg id "$1" '.events[$id]' "$STATE_FILE"; }
# The operator reconciles the interrupted receipt before intake resumes.
update_json "$STATE_FILE" '.events.interrupted="rejected"'
key=$(ask_key)
long=$(head -c 600 /dev/zero | tr '\0' x)
set_events "$key" "{\"eventId\":\"too-long\",\"text\":\"$long\"}"
"$ROOT/bin/fm-sharkboard.sh" answers || fail 'a refused reply wedged answer intake'
[ "$(receipt too-long)" = rejected ] || fail 'refused reply not recorded as rejected'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'refused reply released held work'
grep -l -F 'not applied (text_too_long)' "$FM_HOME"/state/inbox/*.note >/dev/null || fail 'refused reply did not reach the lead'
[ "$(jq '.acked' "$FAKE_SHARK_STATE")" = 1 ] || fail 'refused reply acknowledged'
"$ROOT/bin/fm-sharkboard.sh" answers || fail 'intake stayed wedged after a refused reply'
pass 'a definite fm-board refusal becomes a terminal receipt and an inbox note'
set_events "$key" '{"eventId":"odd-client","optionId":"yes","answeredVia":"android"}' '{"eventId":"gone-option","optionId":"opt-6"}'
"$ROOT/bin/fm-sharkboard.sh" answers || fail 'an unexpected event wedged answer intake'
[ "$(receipt odd-client)/$(receipt gone-option)" = rejected/rejected ] || fail 'unexpected events not rejected'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'unexpected event released held work'
pass 'unexpected provenance and withdrawn options are rejected per event'
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" 'del(.asks[$key]) | .events=[]'
"$ROOT/bin/fm-sharkboard.sh" answers || fail 'a missing remote ask wedged answer intake'
[ "$(jq -r --arg key "$key" '.rows[$key].askId' "$STATE_FILE")" = "$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE")" ] \
  || fail 'missing remote ask was not republished with its new identity'
set_events "$key" '{"eventId":"odd-again","optionId":"yes","answeredVia":"android"}' '{"eventId":"after-poison","optionId":"no"}'
"$ROOT/bin/fm-sharkboard.sh" answers
[ "$(receipt after-poison)" = acked ] || fail 'a valid answer after a rejected event was not applied'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'No released the held work'
pass 'a missing remote ask is republished and later events still apply'
# A publish whose response is lost must not let its answer pass the cursor.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Third question' >/dev/null
printf 'ask-lost\n' > "$FAKE_SHARK_FAIL"
if "$ROOT/bin/fm-sharkboard.sh" publish 2>/dev/null; then fail 'lost publish response reported success'; fi
rm "$FAKE_SHARK_FAIL"
key=$(jq -r '[.rows|to_entries[]|select(.value.published==false)][0].key' "$STATE_FILE")
[ "$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE")" != null ] || fail 'fixture did not land the lost publish'
set_events "$key" '{"eventId":"after-lost-put","optionId":"no"}'
"$ROOT/bin/fm-sharkboard.sh" sync
[ "$(receipt after-lost-put)" = acked ] || fail 'answer to a publish with a lost response was skipped'
pass 'pending publication identity is recovered before answers advance the cursor'
# A lock left by a dead process is cleared; a live owner's lock is kept.
sh -c 'exit 0' & dead=$!
wait "$dead"
mkdir "$FM_HOME/state/sharkboard/lock"
printf '{"pid":%s,"start":"1"}' "$dead" > "$FM_HOME/state/sharkboard/lock/owner"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'stale lock from a dead owner blocked publication'
[ ! -e "$FM_HOME/state/sharkboard/lock" ] || fail 'lock not released'
mkdir "$FM_HOME/state/sharkboard/lock"
printf '{"pid":%s,"start":"%s"}' "$$" "$(sed 's/.*) //' "/proc/$$/stat" | cut -d' ' -f20)" > "$FM_HOME/state/sharkboard/lock/owner"
if "$ROOT/bin/fm-sharkboard.sh" publish 2>/dev/null; then fail 'live lock owner was displaced'; fi
[ -e "$FM_HOME/state/sharkboard/lock/owner" ] || fail 'live owner lock was removed'
rm -r "$FM_HOME/state/sharkboard/lock"
pass 'dead lock owners are reaped and live owners are respected'
# Later arrives as a snooze on the open ask and defers the hold to a date.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Fourth question' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
key=$(ask_key)
today=$(date -u +%Y-%m-%d)
tomorrow=$(node -e 'console.log(new Date(Date.now() + 86400000).toISOString().slice(0, 10))')
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" --arg until "${today}T23:59:00.000Z" '.asks[$key].snoozeUntil=$until | .events=[]'
acked=$(jq '.acked' "$FAKE_SHARK_STATE")
"$ROOT/bin/fm-sharkboard.sh" answers
[ "$(receipt "$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE"):snooze:${today}T23:59:00.000Z")" = applied ] || fail 'snooze not applied as Later'
grep -h -F "deferred until $tomorrow" "$FM_HOME"/state/inbox/*.note >/dev/null || fail 'a same-day snooze was not rounded to the next date'
[ "$(jq '.acked' "$FAKE_SHARK_STATE")" = "$acked" ] || fail 'snooze acknowledged as a terminal answer'
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = cancelled ] || fail 'deferred ask was not cancelled'
pass 'Later snoozes defer the hold to a date and retire the ask'
# Active work heartbeats on every publish; disappeared work, notes and asks are retired.
fm_write_meta "$FM_HOME/state/live-work.meta" "window=firstmate:fm-live-work" "endpoint_task_id=live-work" "kind=ship" "harness=codex"
printf '[{"text":"Heads up from the fixture","kind":"fyi"}]\n' > "$FM_HOME/data/board-notes.json"
printf -- '- [ ] other-work - Other work (repo: sample) (kind: ship) (since 2026-10-01)\n' > "$TMP_ROOT/other"
sed -i "/^## Queued$/r $TMP_ROOT/other" "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-sharkboard.sh" publish
work_puts() { jq --arg title "$1" '[.calls[]|select(.verb=="work" and .body.title==$title)]|length' "$FAKE_SHARK_STATE"; }
[ "$(work_puts live-work)" = 1 ] && [ "$(work_puts 'Other work')" = 1 ] || fail 'work rows not published'
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(work_puts live-work)" = 2 ] || fail 'in-flight work did not heartbeat'
[ "$(work_puts 'Other work')" = 1 ] || fail 'unchanged queued work republished'
note_key=$(jq -r '.notes|keys[0]' "$FAKE_SHARK_STATE")
update_json "$FAKE_SHARK_STATE" 'del(.notes[])'
rm "$FM_HOME/state/live-work.meta" "$FM_HOME/data/board-notes.json"
sed -i '/other-work/d' "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'disappeared rows wedged publication'
[ "$(jq -r '[.work[]|select(.done=="closed")]|length' "$FAKE_SHARK_STATE")" = 2 ] || fail 'disappeared work not closed'
[ "$(jq --arg key "$note_key" '[.calls[]|select(.verb=="note" and .key==$key)]|length' "$FAKE_SHARK_STATE")" = 2 ] || fail 'disappeared note not cleared'
[ "$(jq --arg key "$note_key" '.rows[$key]' "$STATE_FILE")" = null ] || fail 'cleared note kept in state'
pass 'in-flight heartbeat and idempotent retirement of work, notes and asks'
# A transient intake failure records nothing and keeps the page for a retry.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Fifth question' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
key=$(ask_key)
cursor=$(jq -r '.cursor' "$STATE_FILE")
set_events "$key" '{"eventId":"transient","optionId":"no"}'
update_json "$FAKE_SHARK_STATE" '.cursor="cursor-next"'
chmod 555 "$FM_HOME/data"
"$ROOT/bin/fm-sharkboard.sh" answers || { chmod 755 "$FM_HOME/data"; fail 'a transient intake failure wedged answers'; }
chmod 755 "$FM_HOME/data"
[ "$(receipt transient)" = null ] || fail 'transient intake failure left a receipt'
[ "$(jq -r '.cursor' "$STATE_FILE")" = "$cursor" ] || fail 'transient intake failure advanced the cursor'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'transient failure released held work'
"$ROOT/bin/fm-sharkboard.sh" answers
[ "$(receipt transient)" = acked ] || fail 'transient intake failure was not retried'
[ "$(jq -r '.cursor' "$STATE_FILE")" = cursor-next ] || fail 'cursor did not advance after the retry'
pass 'transient intake failures retry without a receipt or cursor progress'
# serve logs a failed tick and keeps polling.
answer_calls() { jq '[.calls[]|select(.verb=="answers")]|length' "$FAKE_SHARK_STATE" 2>/dev/null || echo 0; }
wait_calls() {  # <count>
  local tries=0
  while [ "$(answer_calls)" -lt "$1" ]; do
    tries=$((tries + 1)); [ "$tries" -lt 300 ] || fail "serve made no answers call $1"
    sleep 0.2
  done
}
rm -f "$FM_HOME/state/sharkboard/pending"
printf 'answers-down\n' > "$FAKE_SHARK_FAIL"
before=$(answer_calls)
"$ROOT/bin/fm-sharkboard.sh" serve 2> "$TMP_ROOT/serve.err" & serve_pid=$!
trap 'kill "$serve_pid" 2>/dev/null || true; fm_test_cleanup' EXIT
wait_calls $((before + 1))
rm "$FAKE_SHARK_FAIL"
touch "$FM_HOME/state/sharkboard/pending"
wait_calls $((before + 2))
kill -0 "$serve_pid" 2>/dev/null || fail 'serve exited after a failed tick'
grep -q 'retrying' "$TMP_ROOT/serve.err" || fail 'serve did not report the failed tick'
kill "$serve_pid"; wait "$serve_pid" 2>/dev/null || true
pass 'serve survives a transient tick failure'
