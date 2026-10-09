#!/usr/bin/env bash
set -u
ROOT=$1 W=$2; rm -rf "$W"; mkdir -p "$W"
export FM_HOME="$W/home" FM_SHARKBOARD_CONFIG="$W/token.json"
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/config"
TOK=hark_$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 43)
printf '{"token":"%s","apiUrl":"http://127.0.0.1:47811/"}\n' "$TOK" > "$FM_SHARKBOARD_CONFIG"; chmod 600 "$FM_SHARKBOARD_CONFIG"
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n- [ ] adv-hold - Adversarial decision (repo: sample) (kind: ship) (since 2026-10-01)\n- [ ] adv-queued - Plain queued work (repo: sample) (kind: ship) (since 2026-10-01)\n\n## Done\n' > "$FM_HOME/data/backlog.md"
node emu.mjs 47811 "$W/real.log" "$TOK" "$W/events.json" & E1=$!
trap 'kill $E1 2>/dev/null' EXIT; sleep 0.5
"$ROOT/bin/fm-captain-hold.sh" hold adv-hold --reason 'Approve deploy?' >/dev/null
"$ROOT/bin/fm-sharkboard.sh" publish; echo "publish exit $?"
echo "== published rows:"; jq -c 'select(.method=="PUT")|{path,state:.body.state,title:.body.title,push:.body.push}' "$W/real.log"
A=$(curl -s -H "authorization: Bearer $TOK" http://127.0.0.1:47811/api/agent/board/state | jq -c '.asks|to_entries[0]|{key:.key,id:.value.id,revision:.value.revision}')
echo "$A" | jq -c '[{eventId:"stale-rev",askKey:.key,askId:.id,revision:(.revision+5),status:"answered",waitingTaskId:"adv-hold",optionId:"yes",answeredVia:"web"},
 {eventId:"bad-prov",askKey:.key,askId:.id,revision:.revision,status:"answered",waitingTaskId:"adv-hold",optionId:"yes",answeredVia:"api"},
 {eventId:"other-task",askKey:.key,askId:.id,revision:.revision,status:"answered",waitingTaskId:"adv-queued",optionId:"yes",answeredVia:"web"},
 {eventId:"foreign",askKey:"someone-else:ask:1",askId:"x",revision:1,status:"answered",waitingTaskId:"adv-hold",optionId:"yes",answeredVia:"web"}]' > "$W/events.json"
echo "== injected: Yes at wrong revision; Yes via unexpected provenance 'api'; Yes scoped to another task; Yes on a foreign key"
"$ROOT/bin/fm-sharkboard.sh" answers; echo "answers exit $?"
echo "== hold still open (nothing released)?"; "$ROOT/bin/fm-captain-hold.sh" open adv-hold && echo "yes, held"
echo "== receipts:"; jq -c '.events' "$FM_HOME/state/sharkboard/last.json"
echo "== ack calls: $(jq -s '[.[]|select(.path|test("/ack$"))]|length' "$W/real.log")"
echo "== inbox notes:"; cat "$FM_HOME"/state/inbox/*.note | grep -E 'SHark board event|Untrusted'
echo "== worker guard (FM_TASK_ID set, real guard shim in front of real sharkctl):"
G="$W/guard"; mkdir -p "$G"; ln -s "$ROOT/bin/fm-sharkctl-guard.sh" "$G/sharkctl"
for v in answers ack ask; do FM_TASK_ID=worker-1 PATH="$G:$PATH" HARK_CONFIG="$FM_SHARKBOARD_CONFIG" sharkctl board $v --key k; echo "[board $v exit $?]"; done
n0=$(wc -l < "$W/real.log"); PATH="$G:$PATH" HARK_CONFIG="$FM_SHARKBOARD_CONFIG" sharkctl board answers --json >/dev/null; echo "[unmarked lead board answers exit $? ; server requests +$(( $(wc -l < "$W/real.log") - n0 ))]"
