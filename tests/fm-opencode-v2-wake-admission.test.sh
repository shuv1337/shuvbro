#!/usr/bin/env bash
# Wake handoff and admission sequencing for the OpenCode V2 adapter, against the
# real recovery helpers and exact-ID steer journal.
#
# Part 1 pins the helper contract the adapter must respect: the handling
# handoff (`fm-watch-arm.sh --handling-delivered`) is accepted while the
# episode is still open, and rejected once the lead has drained and
# acknowledged it. A confirmation issued after prompt admission therefore races
# the lead's own acknowledgement, most visibly when an admission acknowledgement
# is lost and retried after backoff.
#
# The adapter-level admission outcomes (one admitted logical wake across
# rejected admissions and lost receipts, durable rows kept until the lead
# acknowledges, no stranded wake after an outage, owner retirement) run against
# the native TUI entry in tests/fm-opencode-v2-tui-acceptance.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# Fixture boundary: no ambient native session identity or activation, and a
# token-only registry namespace for any production helper this run reaches.
unset OPENCODE_SESSION_ID FM_V2_ACTIVATION
# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"
v2_assert_test_namespace || exit 1

# Cross-tree runs (FM_V2_TEST_CODE_ROOT) exercise that tree's recovery helpers,
# matching the acceptance library's code-root selection.
CODE_ROOT=$(cd -P "${FM_V2_TEST_CODE_ROOT:-$ROOT}" && pwd -P)
WATCH_ARM="$CODE_ROOT/bin/fm-watch-arm.sh"
DRAIN="$CODE_ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-wake-admission)
export NODE_NO_WARNINGS=1
ARM_PID=

test_journal_steers_with_exact_receipts_and_canonical_ack() {
  local out
  out=$(CODE_ROOT="$CODE_ROOT" LAB="$TMP_ROOT/journal" node --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const {createAdmissionJournal}=await import(pathToFileURL(process.env.CODE_ROOT+'/.opencode/plugins/fm-native-v2/admission.js'));
const paths={state:process.env.LAB};
fs.mkdirSync(paths.state,{recursive:true,mode:0o700});
const queue=paths.state+'/.wake-queue', row='100\t1\tsignal\ttask\tready\n';
fs.writeFileSync(queue,row);
const calls=[];
const admit=async input=>{calls.push(input);return {id:calls.length===1?'msg_wrong_receipt':input.id};};
const journal=createAdmissionJournal(paths,'ses_steer',admit,()=>{});
const wake=journal.prepare('original wake');
await assert.rejects(journal.deliver(wake),/successor confirmation/);
assert.equal(calls.length,0);
const confirmed=journal.confirm(wake);
await Promise.all([journal.deliver(confirmed),journal.deliver(confirmed)]);
assert.equal(calls.length,2,'wrong exact-ID receipt must retry; concurrent delivery must coalesce');
assert.equal(calls[0].delivery,'steer');
assert.deepEqual(calls[0],calls[1]);
assert.equal(fs.readFileSync(queue,'utf8'),row,'native receipt must not acknowledge canonical rows');
const reloaded=createAdmissionJournal(paths,'ses_steer',admit,()=>{});
await reloaded.deliver(confirmed);
assert.equal(calls.length,2,'admitted identity must survive journal reload');

// The lead can handle a steer before its native receipt arrives. Canonical
// acknowledgement retires a lost-receipt retry without claiming admission.
fs.writeFileSync(queue,'101\t2\tsignal\ttask\tnext\n');
let lostCalls=0;
const lost=createAdmissionJournal(paths,'ses_steer',async input=>{
  assert.equal(input.delivery,'steer');lostCalls++;
  fs.writeFileSync(queue,'');throw new Error('receipt lost after canonical handling');
},()=>{});
const handled=lost.confirm(lost.prepare('handled during admission'));
assert.equal(await lost.deliver(handled),true);
assert.equal(lostCalls,1);
const records=fs.readdirSync(paths.state+'/.opencode-v2-admissions',{recursive:true});
const record=records.find(name=>name.endsWith(handled.id+'.json'));
assert.equal(JSON.parse(fs.readFileSync(paths.state+'/.opencode-v2-admissions/'+record)).phase,'acknowledged');
assert.equal(lost.pending().length,0);

// Startup and repair prompts share the lead journal and need prompt delivery
// even if activation or a supervision failure happens during an existing turn.
for(const kind of ['startup:claim','failure:claim:episode:reason']) {
  const notice=reloaded.prepare(kind,kind);
  await reloaded.deliver(notice);
  assert.equal(calls.at(-1).delivery,'steer');
  assert.equal(calls.at(-1).id,notice.id);
  const count=calls.length;
  await reloaded.deliver(reloaded.prepare('replacement text',kind));
  assert.equal(calls.length,count);
}
console.log('lead wakes, startup and repairs steer with stable IDs; exact receipts and canonical acknowledgements remain distinct');
JS
  ) || fail "$out"
  pass "$out"
}

# The lead's handling turn: drain, then the generation-bound acknowledgement.
lead_drain_and_ack() {  # <state>
  local state=$1
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$state/.lead-drain.out" 2> "$state/.lead-drain.err" || return 1
  ack_drain_err "$state" "$state/.lead-drain.err"
}

start_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  while [ "$i" -lt 100 ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
}

# Real first cycle delivers one signal wake; then a handling successor starts.
# Sets EP_GENERATION and EP_WATCHER for the successor; ARM_PID is its arm.
EP_GENERATION=
EP_WATCHER=
open_handling_episode() {  # <dir>
  local dir=$1 home=$1/home state=$1/state fakebin=$1/fakebin first generation pid
  mkdir -p "$home/data"
  start_arm "$home" "$state" "$fakebin" "$dir/first.out"
  first=$ARM_PID
  printf 'done: alpha finished\n' > "$state/alpha.status"
  wait_for_exit "$first" 120 >/dev/null || fail "fixture watcher did not deliver its wake"
  grep -q '^signal:' "$dir/first.out" || fail "first cycle did not report its wake: $(cat "$dir/first.out")"
  start_arm "$home" "$state" "$fakebin" "$dir/successor.out" "$first"
  generation=$(sed -n 's/^watcher: started pid=[0-9]*.* recovery-generation=\([A-Za-z0-9._-]*\)$/\1/p' "$dir/successor.out")
  pid=$(sed -n 's/^watcher: started pid=\([0-9]*\).* recovery-generation=.*$/\1/p' "$dir/successor.out")
  [ -n "$generation" ] && [ -n "$pid" ] || fail "handling successor did not report a recovery generation: $(cat "$dir/successor.out")"
  EP_GENERATION=$generation
  EP_WATCHER=$pid
}

test_handoff_before_lead_ack_is_accepted() {
  local dir state generation pid
  dir=$(make_case handoff-before-ack)
  state="$dir/state"
  open_handling_episode "$dir"
  generation=$EP_GENERATION
  pid=$EP_WATCHER
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" --watcher-pid "$pid" \
    || fail "handoff confirmation was rejected while the episode was open"
  lead_drain_and_ack "$state" || fail "lead acknowledgement after an accepted handoff failed"
  case "$(cat "$state/.watcher-down")" in acked:*:"$generation") ;; *) fail "episode not retired: $(cat "$state/.watcher-down")" ;; esac
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged wake stayed queued"
  kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
  pass "helper contract: handoff confirmed before the lead acknowledges is accepted and the episode retires"
}

test_handoff_after_lead_ack_is_rejected() {
  local dir state generation pid status=0
  dir=$(make_case handoff-after-ack)
  state="$dir/state"
  open_handling_episode "$dir"
  generation=$EP_GENERATION
  pid=$EP_WATCHER
  # The lead received the wake (admission succeeded), drained and acknowledged
  # it before the adapter's late confirmation ran.
  lead_drain_and_ack "$state" || fail "lead acknowledgement failed"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" --watcher-pid "$pid" \
    || status=$?
  [ "$status" -ne 0 ] || fail "a handoff confirmed after the lead acknowledged the episode was accepted"
  is_live_non_zombie "$ARM_PID" || fail "the live successor did not survive the rejected late handoff"
  kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
  pass "helper contract: a handoff confirmed after the lead acknowledged is rejected, so confirmation must precede admission"
}

FAILED=0
for t in \
  test_journal_steers_with_exact_receipts_and_canonical_ack \
  test_handoff_before_lead_ack_is_accepted \
  test_handoff_after_lead_ack_is_rejected; do
  ( "$t" ) || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] || { printf 'not ok - %s wake admission case(s) failed\n' "$FAILED" >&2; exit 1; }
