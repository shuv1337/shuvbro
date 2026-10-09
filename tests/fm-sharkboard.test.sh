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
if (process.env.HARK_TOKEN || process.env.HARK_API_URL || process.env.HARK_CONFIG !== process.env.FM_SHARKBOARD_CONFIG) {
  console.error('unexpected ambient SHark auth override'); process.exit(3);
}
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
if (/hark_[A-Za-z0-9_-]{40,}/.test(JSON.stringify([body, a]))) { save(); console.error('Refusing to send board content that looks like a SHark API token'); process.exit(2); }
const single = (v, max) => typeof v === 'string' && v.trim().length > 0 && v.length <= max && !/[\x00-\x1f\x7f\p{Cf}]/u.test(v);
const multi = (v, max) => v === undefined || (typeof v === 'string' && v.length <= max && !/\p{Cf}/u.test(v));
const invalid = verb === 'ask' ? !(single(body.title, 120) && multi(body.body, 2000) && (body.options ?? []).every(o => single(o.label, 120)))
  : verb === 'note' && !a.includes('--clear') ? !(single(body.text, 300) && multi(body.detail, 2000) && (body.link === undefined || body.link.startsWith('https://')))
  : verb === 'work' ? !(single(body.title, 120) && (body.statusLabel === undefined || single(body.statusLabel, 60))) : false;
if (invalid) refuse(`Invalid ${verb}`);
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
if (verb === 'cancel' && fail === 'cancel-race') {
  const ask = s.asks[key];
  ask.status = 'answered';
  s.events = [{eventId:'snooze-race',askKey:key,askId:ask.id,revision:ask.revision,status:'answered',waitingTaskId:'bridge-test',optionId:'no',answeredVia:'ios_app'}];
  refuse('No open ask with that key');
}
if (verb === 'cancel') {
  if (s.asks[key]?.status !== 'open') refuse('No open ask with that key');
  s.asks[key].status = 'cancelled';
  out = {ask: s.asks[key]};
}
if (verb === 'answers') out = {events: s.events, cursor: s.cursor ?? 'cursor'};
if (verb === 'ack') {
  if (!s.asks[key] || s.asks[key].acked) refuse('No unacknowledged resolved ask with that key');
  s.asks[key].acked = true;
  s.acked = (s.acked ?? 0) + 1;
}
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
HARK_TOKEN=synthetic-ambient-credential HARK_API_URL=https://wrong.example.invalid "$ROOT/bin/fm-sharkboard.sh" publish
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
"$ROOT/bin/fm-sharkboard.sh" answers || fail 'uncertain answer blocked unrelated intake'
[ "$(jq -r '[.rows[]|select(.quarantine.eventId=="interrupted")]|length' "$FM_HOME/state/sharkboard/last.json")" = 1 ] || fail 'interrupted receipt was not quarantined'
[ "$(jq '.acked' "$FAKE_SHARK_STATE")" = 1 ] || fail 'uncertain answer acknowledged'
pass 'new lifecycle forwards a stale approval and interrupted receipt quarantines its ask'

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
# Explicit operator reconciliation settles the receipt without replaying its answer.
key=$(ask_key)
"$ROOT/bin/fm-sharkboard.sh" reconcile --key "$key" --receipt interrupted --outcome not-recorded
"$ROOT/bin/fm-sharkboard.sh" sync
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
[ "$(work_puts 'Other work')" = 2 ] || fail 'queued work did not heartbeat'
note_key=$(jq -r '.notes|keys[0]' "$FAKE_SHARK_STATE")
update_json "$FAKE_SHARK_STATE" 'del(.notes[])'
rm "$FM_HOME/state/live-work.meta" "$FM_HOME/data/board-notes.json"
sed -i '/other-work/d' "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'disappeared rows wedged publication'
[ "$(jq -r '[.work[]|select(.done=="closed")]|length' "$FAKE_SHARK_STATE")" = 2 ] || fail 'disappeared work not closed'
[ "$(jq --arg key "$note_key" '[.calls[]|select(.verb=="note" and .key==$key)]|length' "$FAKE_SHARK_STATE")" = 2 ] || fail 'disappeared note not cleared'
[ "$(jq --arg key "$note_key" '.rows[$key]' "$STATE_FILE")" = null ] || fail 'cleared note kept in state'
pass 'active work heartbeat and idempotent retirement of work, notes and asks'
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
# Presentation fields are normalized to SHark's contract before publication.
long_line="$(head -c 340 /dev/zero | tr '\0' n)"
jq -n --arg text "First line
$long_line" --arg detail "$(head -c 2100 /dev/zero | tr '\0' d)" \
  '[{text:$text,detail:$detail,link:"http://example.invalid/plain",kind:"fyi"},{text:"Call me\nback",kind:"you"}]' > "$FM_HOME/data/board-notes.json"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'contract-invalid presentation fields were published unnormalized'
jq -e '.notes[] | select(.text|startswith("First line")) | (.text|length) <= 300 and (.text|test("\n")|not) and (.detail|length) <= 2000 and (has("link")|not)' "$FAKE_SHARK_STATE" >/dev/null \
  || fail 'FYI note not normalized'
jq -e '[.asks[] | select(.title=="Call me back")] | length == 1' "$FAKE_SHARK_STATE" >/dev/null || fail 'multi-line ask title not normalized'
pass 'note text, detail, link and ask titles are normalized to the SHark contract'
# A permanently refused row is skipped without blocking captain intake or other rows.
secret="hark_$(head -c 44 /dev/zero | tr '\0' Z)"
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Sixth question' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
key=$(ask_key)
jq -n --arg secret "$secret" '[{text:("Token " + $secret),kind:"fyi"},{text:("Ask " + $secret),kind:"you"}]' > "$FM_HOME/data/board-notes.json"
if "$ROOT/bin/fm-sharkboard.sh" publish 2> "$TMP_ROOT/refused.err"; then fail 'refused rows reported success'; fi
[ "$(jq '[.notes[]|select(.text|startswith("First line"))]|length' "$FAKE_SHARK_STATE")" = 0 ] || fail 'a refused row blocked retirement of other rows'
set_events "$key" '{"eventId":"beside-refused","optionId":"no"}'
if "$ROOT/bin/fm-sharkboard.sh" sync 2>> "$TMP_ROOT/refused.err"; then fail 'refused rows reported success'; fi
[ "$(receipt beside-refused)" = acked ] || fail 'a refused row blocked captain intake'
if grep -q -F "$secret" "$TMP_ROOT/refused.err"; then fail 'refused content was logged'; fi
rm "$FM_HOME/data/board-notes.json"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'retiring never-published rows failed'
pass 'refused rows are skipped and logged without content while intake and retirement continue'
# An answer that lands while its row is being retired is still forwarded.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Seventh question' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
key=$(ask_key)
set_events "$key" '{"eventId":"racing-retirement","text":"Phone reply racing retirement"}'
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Eighth question' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq -r --arg key "$key" '.rows[$key].retired' "$STATE_FILE")" = true ] || fail 'answered ask retired before its answer was read'
"$ROOT/bin/fm-sharkboard.sh" answers
[ "$(receipt racing-retirement)" = rejected ] || fail 'answer racing retirement was not forwarded'
grep -h -F 'Untrusted captain answer: Phone reply racing retirement' "$FM_HOME"/state/inbox/*.note >/dev/null || fail 'racing reply text did not reach the lead'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'racing reply released held work'
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq --arg key "$key" '.rows[$key]' "$STATE_FILE")" = null ] || fail 'retired ask kept after its answer was forwarded'
pass 'an answer racing retirement is forwarded before the row is dropped'
# An ack that lands with its response lost is not retried into a wedge.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Ninth question' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
key=$(ask_key)
set_events "$key" '{"eventId":"lost-ack","optionId":"no"}'
printf 'ack-lost\n' > "$FAKE_SHARK_FAIL"
if "$ROOT/bin/fm-sharkboard.sh" answers 2>/dev/null; then fail 'lost ack response reported success'; fi
rm "$FAKE_SHARK_FAIL"
[ "$(receipt lost-ack)" = applied ] || fail 'applied answer lost its receipt'
"$ROOT/bin/fm-sharkboard.sh" sync || fail 'an ack that already landed wedged the bridge'
[ "$(receipt lost-ack)" = acked ] || fail 'landed ack not recorded'
pass 'an ack whose response was lost settles on the next tick'
# Work SHark never created retires without resending its refused title.
printf -- '- [ ] secret-work - Ship %s (repo: sample) (kind: ship) (since 2026-10-01)\n' "$secret" > "$TMP_ROOT/secret-work"
sed -i "/^## Queued$/r $TMP_ROOT/secret-work" "$FM_HOME/data/backlog.md"
if "$ROOT/bin/fm-sharkboard.sh" publish 2>/dev/null; then fail 'refused work reported success'; fi
sed -i '/secret-work/d' "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'never-created work could not be retired'
[ "$(jq '[.rows[]|select(.payload.title|test("hark_"))]|length' "$STATE_FILE")" = 0 ] || fail 'never-created work kept in state'
pass 'never-created work retires once SHark confirms it has no such item'
# A captain dismissal is forwarded and acknowledged, then an unchanged local hold returns.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Dismissal recovery' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
key=$(ask_key)
old_id=$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE")
set_events "$key" '{"eventId":"dismissed","status":"cancelled","answeredVia":"ios_app"}'
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" '.asks[$key].status="cancelled"'
printf 'ack-lost\n' > "$FAKE_SHARK_FAIL"
if "$ROOT/bin/fm-sharkboard.sh" sync 2>/dev/null; then fail 'lost dismissal ack reported success'; fi
[ "$(receipt dismissed)" = applied ] || fail 'dismissal receipt lost after ack response loss'
rm "$FAKE_SHARK_FAIL"
"$ROOT/bin/fm-sharkboard.sh" sync
[ "$(receipt dismissed)" = acked ] || fail 'captain dismissal was not acknowledged'
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = open ] || fail 'dismissed local hold did not return'
[ "$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE")" != "$old_id" ] || fail 'dismissal reused terminal ask'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'dismissal released local hold'
pass 'captain dismissals are acknowledged and still-local holds are reasserted'
# A captain dismissal that races retirement is still forwarded and acknowledged.
key=$(ask_key)
set_events "$key" '{"eventId":"dismissal-race","status":"cancelled","answeredVia":"web"}'
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" '.asks[$key].status="cancelled"'
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'After dismissal race' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq -r --arg key "$key" '.rows[$key].retired' "$STATE_FILE")" = true ] || fail 'dismissed ask retired before its dismissal was read'
printf 'ack-lost\n' > "$FAKE_SHARK_FAIL"
if "$ROOT/bin/fm-sharkboard.sh" answers 2>/dev/null; then fail 'lost racing dismissal ack reported success'; fi
rm "$FAKE_SHARK_FAIL"
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq -r --arg key "$key" '.rows[$key].retired' "$STATE_FILE")" = true ] || fail 'dismissal dropped before its ack settled'
"$ROOT/bin/fm-sharkboard.sh" answers
[ "$(receipt dismissal-race)" = acked ] || fail 'racing dismissal was not acknowledged'
"$ROOT/bin/fm-sharkboard.sh" publish
[ "$(jq --arg key "$key" '.rows[$key]' "$STATE_FILE")" = null ] || fail 'retired dismissal kept after acknowledgment'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'racing dismissal released local hold'
pass 'a captain dismissal racing retirement is acknowledged before the row is dropped'
# A refused far-future snooze must not hide a still-open local question.
key=$(ask_key)
far=$(node -e 'console.log(new Date(Date.now()+400*86400000).toISOString())')
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" --arg until "$far" '.asks[$key].snoozeUntil=$until | .events=[]'
old_id=$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE")
"$ROOT/bin/fm-sharkboard.sh" sync
[ "$(receipt "$old_id:snooze:$far")" = rejected ] || fail 'far-future snooze not refused'
[ "$(jq -r --arg key "$key" '.asks[$key].snoozeUntil' "$FAKE_SHARK_STATE")" = null ] || fail 'rejected snooze remained hidden'
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = open ] || fail 'rejected snooze lost the question'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'refused snooze released local hold'
pass 'rejected snoozes restore visibility without applying Later'
# Cancellation may land with a lost response; confirmed terminal state permits repair.
key=$(ask_key)
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" --arg until "$far" '.asks[$key].snoozeUntil=$until | .events=[]'
printf 'cancel-lost\n' > "$FAKE_SHARK_FAIL"
"$ROOT/bin/fm-sharkboard.sh" sync
rm "$FAKE_SHARK_FAIL"
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = open ] || fail 'lost cancel response wedged snooze repair'
[ "$(jq -r --arg key "$key" '.asks[$key].snoozeUntil' "$FAKE_SHARK_STATE")" = null ] || fail 'lost cancel response left question hidden'
pass 'snooze repair confirms cancellation despite response loss'
# An answer racing snooze recovery must be consumed before any new question opens.
key=$(ask_key)
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" --arg until "$far" '.asks[$key].snoozeUntil=$until | .events=[]'
printf 'cancel-race\n' > "$FAKE_SHARK_FAIL"
"$ROOT/bin/fm-sharkboard.sh" sync
rm "$FAKE_SHARK_FAIL"
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = answered ] || fail 'snooze repair overwrote a racing answer'
"$ROOT/bin/fm-sharkboard.sh" sync
[ "$(receipt snooze-race)" = acked ] || fail 'racing answer was not consumed'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'racing No released local hold'
pass 'an answer racing rejected-snooze recovery remains available for intake'
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Before stale snooze' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
# A stale-card snooze retires its old question and keeps the replacement visible.
key=$(ask_key)
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" --arg until "$far" '.asks[$key].snoozeUntil=$until'
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Replacement after stale snooze' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" sync
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = cancelled ] || fail 'stale snoozed ask remained open'
key=$(ask_key)
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = open ] || fail 'replacement question not visible'
pass 'stale snoozes retire without hiding the replacement question'
# Recovery locks carry owners too: a dead reaper is recoverable, a live one is kept.
sh -c 'exit 0' & dead=$!
wait "$dead"
mkdir "$FM_HOME/state/sharkboard/lock" "$FM_HOME/state/sharkboard/lock.reap"
printf '{"pid":%s,"start":"1"}' "$dead" > "$FM_HOME/state/sharkboard/lock/owner"
printf '{"pid":%s,"start":"1"}' "$$" > "$FM_HOME/state/sharkboard/lock.reap/owner"
# A real live identity must be used: start mismatch represents a reused PID.
printf '{"pid":%s,"start":"%s"}' "$$" "$(sed 's/.*) //' "/proc/$$/stat" | cut -d' ' -f20)" > "$FM_HOME/state/sharkboard/lock.reap/owner"
if "$ROOT/bin/fm-sharkboard.sh" publish 2>/dev/null; then fail 'live reaper displaced'; fi
[ -f "$FM_HOME/state/sharkboard/lock.reap/owner" ] || fail 'live reaper removed'
printf '{"pid":%s,"start":"1"}' "$dead" > "$FM_HOME/state/sharkboard/lock.reap/owner"
"$ROOT/bin/fm-sharkboard.sh" publish || fail 'dead reaper wedged publication'
[ ! -e "$FM_HOME/state/sharkboard/lock.reap" ] || fail 'reaper lock leaked'
pass 'abandoned reaper locks recover while live reapers retain ownership'
# A legacy ownerless reap directory cannot prove a dead owner and is never taken over.
mkdir "$FM_HOME/state/sharkboard/lock" "$FM_HOME/state/sharkboard/lock.reap"
printf '{"pid":%s,"start":"1"}' "$dead" > "$FM_HOME/state/sharkboard/lock/owner"
if "$ROOT/bin/fm-sharkboard.sh" publish 2>/dev/null; then fail 'ownerless legacy reaper was taken over'; fi
[ -d "$FM_HOME/state/sharkboard/lock.reap" ] && [ -f "$FM_HOME/state/sharkboard/lock/owner" ] || fail 'ownerless legacy reaper or its lock was removed'
rm -r "$FM_HOME/state/sharkboard/lock" "$FM_HOME/state/sharkboard/lock.reap"
pass 'ownerless legacy reaper locks require manual reconciliation'
# An uncertain intake is isolated durably, even when the local lead alert fails.
qbin="$TMP_ROOT/quarantine-bin"
mkdir "$qbin"
cp "$ROOT/bin/fm-sharkboard.sh" "$ROOT/bin/fm-sharkboard.mjs" "$qbin/"
export FM_TEST_REAL_BIN="$ROOT/bin" FM_TEST_ANSWER_CALLS="$TMP_ROOT/intake-calls" FM_TEST_ALERT_FAIL="$TMP_ROOT/alert-fail" FM_TEST_CRASH_FILE="$TMP_ROOT/crash-intake"
cat > "$qbin/fm-board.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = answer ]; then
  printf 'answer\n' >> "$FM_TEST_ANSWER_CALLS"
  # The local operation may have committed before its repair/report failed.
  "$FM_TEST_REAL_BIN/fm-board.sh" "$@" >/dev/null
  if [ -e "$FM_TEST_CRASH_FILE" ]; then kill -KILL "$PPID"; exit 1; fi
  printf '{"ok":false,"code":"repair_failed"}\n'
  exit 1
fi
exec "$FM_TEST_REAL_BIN/fm-board.sh" "$@"
SH
cat > "$qbin/fm-inbox.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_TEST_ALERT_FAIL" ] || exit 1
exec "$FM_TEST_REAL_BIN/fm-inbox.sh" "$@"
SH
chmod +x "$qbin/"*.sh
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Uncertain intake question' >/dev/null
fm_write_meta "$FM_HOME/state/quarantine-other.meta" "window=firstmate:fm-quarantine-other" "endpoint_task_id=quarantine-other" "kind=ship" "harness=codex"
printf '[{"text":"Retire this unrelated note","kind":"fyi"}]\n' > "$FM_HOME/data/board-notes.json"
"$qbin/fm-sharkboard.sh" sync
key=$(ask_key)
set_events "$key" '{"eventId":"repair-uncertain","optionId":"no"}'
touch "$FM_TEST_ALERT_FAIL"
printf '[{"text":"Publish unrelated during quarantine","kind":"fyi"}]\n' > "$FM_HOME/data/board-notes.json"
if "$qbin/fm-sharkboard.sh" sync 2>/dev/null; then fail 'failed quarantine alert reported success'; fi
[ "$(receipt repair-uncertain)" = quarantined ] || fail 'repair_failed did not quarantine'
[ "$(wc -l < "$FM_TEST_ANSWER_CALLS" | tr -d ' ')" = 1 ] || fail 'uncertain intake was retried'
[ "$(work_puts quarantine-other)" = 2 ] || fail 'quarantine blocked unrelated heartbeat'
[ "$(jq '[.notes[]|select(.text=="Retire this unrelated note")]|length' "$FAKE_SHARK_STATE")" = 0 ] || fail 'quarantine blocked unrelated retirement'
[ "$(jq '[.notes[]|select(.text=="Publish unrelated during quarantine")]|length' "$FAKE_SHARK_STATE")" = 1 ] || fail 'quarantine blocked unrelated publication'
[ "$(jq -r --arg key "$key" '.rows[$key].quarantine.alerted' "$STATE_FILE")" = false ] || fail 'failed alert marked delivered'
"$qbin/fm-sharkboard.sh" quarantines > "$TMP_ROOT/quarantines"
[ "$(jq '.quarantines|length' "$TMP_ROOT/quarantines")" = 1 ] || fail 'quarantine inspection missing ask'
# The source question changes while quarantined; neither old nor replacement is published.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Changed while quarantined' >/dev/null
before_asks=$(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")
acked=$(jq '.acked' "$FAKE_SHARK_STATE")
rm "$FM_TEST_ALERT_FAIL"
"$qbin/fm-sharkboard.sh" sync
"$qbin/fm-sharkboard.sh" publish
"$qbin/fm-sharkboard.sh" sync
[ "$(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")" = "$before_asks" ] || fail 'quarantined task was republished after model change'
[ "$(wc -l < "$FM_TEST_ANSWER_CALLS" | tr -d ' ')" = 1 ] || fail 'quarantined event replayed after restart'
[ "$(jq '.acked' "$FAKE_SHARK_STATE")" = "$acked" ] || fail 'quarantined event was acknowledged'
[ "$(jq -r --arg key "$key" '.rows[$key].quarantine.alerted' "$STATE_FILE")" = true ] || fail 'quarantine alert was not retried'
[ "$(grep -l 'QUARANTINED:' "$FM_HOME"/state/inbox/*.note | wc -l | tr -d ' ')" = 2 ] || fail 'quarantine alert repeated after successful delivery'
# Wrong identities refuse; explicit reconciliation never invokes answer intake.
if "$qbin/fm-sharkboard.sh" reconcile --key "$key" --receipt wrong --outcome recorded 2>/dev/null; then fail 'wrong reconciliation receipt accepted'; fi
"$qbin/fm-sharkboard.sh" reconcile --key "$key" --receipt repair-uncertain --outcome recorded
"$qbin/fm-sharkboard.sh" reconcile --key "$key" --receipt repair-uncertain --outcome recorded > "$TMP_ROOT/reconcile-repeat"
jq -e '.alreadyReconciled and (.replayed|not)' "$TMP_ROOT/reconcile-repeat" >/dev/null || fail 'reconciliation was not idempotent'
"$qbin/fm-sharkboard.sh" sync
[ "$(receipt repair-uncertain)" = reconciled ] || fail 'explicit outcome not retained'
[ "$(wc -l < "$FM_TEST_ANSWER_CALLS" | tr -d ' ')" = 1 ] || fail 'reconciliation replayed intake'
[ "$(jq '[.calls[]|select(.verb=="ask")]|length' "$FAKE_SHARK_STATE")" -gt "$before_asks" ] || fail 'explicit reconciliation did not unblock the replacement question'
"$ROOT/bin/fm-captain-hold.sh" open bridge-test >/dev/null || fail 'reconciliation released changed hold'
pass 'repair_failed quarantines one ask, retries its alert, preserves changed questions and permits unrelated updates'
# Recover a crash after journaling applying even when the event feed has moved on.
key=$(ask_key)
# shellcheck disable=SC2016
update_json "$STATE_FILE" --arg key "$key" '.rows[$key] as $r | .events["crashed-journal"]="applying" | .intakes["crashed-journal"]={key:$key,event:{eventId:"crashed-journal",askKey:$key,askId:$r.askId,revision:$r.revision,status:"answered",optionId:"yes",answeredVia:"web",waitingTaskId:"bridge-test"}}'
update_json "$FAKE_SHARK_STATE" '.events=[]'
"$qbin/fm-sharkboard.sh" publish
[ "$(receipt crashed-journal)" = quarantined ] || fail 'publish-only did not recover the applying journal'
"$qbin/fm-sharkboard.sh" sync
[ "$(wc -l < "$FM_TEST_ANSWER_CALLS" | tr -d ' ')" = 1 ] || fail 'crashed intake replayed without a feed event'
"$qbin/fm-sharkboard.sh" reconcile --key "$key" --receipt crashed-journal --outcome not-recorded
"$qbin/fm-sharkboard.sh" sync
pass 'publish-only recovers a crashed intake without requiring its event on the feed'
# A process killed after the local action commits leaves applying and recovers only that ask.
key=$(ask_key)
set_events "$key" '{"eventId":"killed-after-record","optionId":"no"}'
touch "$FM_TEST_CRASH_FILE"
if "$qbin/fm-sharkboard.sh" sync 2>/dev/null; then fail 'killed intake reported success'; fi
rm "$FM_TEST_CRASH_FILE"
[ "$(receipt killed-after-record)" = applying ] || fail 'crash did not leave the applying journal'
"$qbin/fm-sharkboard.sh" publish
"$qbin/fm-sharkboard.sh" sync
[ "$(receipt killed-after-record)" = quarantined ] || fail 'killed intake was not quarantined'
[ "$(wc -l < "$FM_TEST_ANSWER_CALLS" | tr -d ' ')" = 2 ] || fail 'killed intake was replayed'
"$qbin/fm-sharkboard.sh" reconcile --key "$key" --receipt killed-after-record --outcome recorded
pass 'an actual post-record process crash recovers into quarantine without replay'
# Later can commit locally before reporting repair_failed; quarantine prevents retirement and reset.
"$ROOT/bin/fm-captain-hold.sh" hold bridge-test --reason 'Uncertain Later repair' >/dev/null
"$qbin/fm-sharkboard.sh" sync
key=$(ask_key)
near=$(node -e 'console.log(new Date(Date.now()+3*86400000).toISOString())')
# shellcheck disable=SC2016
update_json "$FAKE_SHARK_STATE" --arg key "$key" --arg until "$near" '.asks[$key].snoozeUntil=$until | .events=[]'
later_event="$(jq -r --arg key "$key" '.asks[$key].id' "$FAKE_SHARK_STATE"):snooze:$near"
"$qbin/fm-sharkboard.sh" sync
"$qbin/fm-sharkboard.sh" sync
[ "$(receipt "$later_event")" = quarantined ] || fail 'uncertain Later not quarantined'
[ "$(jq -r --arg key "$key" '.asks[$key].snoozeUntil' "$FAKE_SHARK_STATE")" = "$near" ] || fail 'uncertain Later was reset automatically'
[ "$(jq -r --arg key "$key" '.asks[$key].status' "$FAKE_SHARK_STATE")" = open ] || fail 'uncertain Later was retired'
[ "$(wc -l < "$FM_TEST_ANSWER_CALLS" | tr -d ' ')" = 3 ] || fail 'uncertain Later replayed'
"$qbin/fm-sharkboard.sh" reconcile --key "$key" --receipt "$later_event" --outcome recorded
"$qbin/fm-sharkboard.sh" sync
pass 'uncertain Later keeps its remote ask frozen until explicit reconciliation'
rm "$FM_HOME/state/quarantine-other.meta" "$FM_HOME/data/board-notes.json"
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
