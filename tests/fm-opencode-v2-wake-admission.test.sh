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

test_recovery_doorbells_share_the_outstanding_cap() {
  local out
  out=$(CODE_ROOT="$CODE_ROOT" LAB="$TMP_ROOT/recovery-journal" node --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const {createAdmissionJournal}=await import(pathToFileURL(process.env.CODE_ROOT+'/.opencode/plugins/fm-native-v2/admission.js'));
function fixture(name, onAdmission = async () => {}) {
  const paths={state:process.env.LAB+'/'+name};
  fs.mkdirSync(paths.state,{recursive:true,mode:0o700});
  const queue=paths.state+'/.wake-queue',marker=paths.state+'/.watcher-down',calls=[];
  fs.writeFileSync(queue,'');
  const admit=async input=>{calls.push(input);assert.equal(input.delivery,'steer');await onAdmission({input,queue,marker});return {id:input.id};};
  const reload=claim=>createAdmissionJournal(paths,'ses_recovery',admit,()=>{},claim?{claim}:{});
  const journal=reload();
  const recovery=(generation)=>journal.confirm(journal.prepare('drain only','wake',{recovery:{generation}}),{generation});
  const phase=value=>JSON.parse(fs.readFileSync(paths.state+'/.opencode-v2-admissions/'+fs.readdirSync(paths.state+'/.opencode-v2-admissions')[0]+'/'+value.id+'.json')).phase;
  return {queue,marker,calls,journal,recovery,reload,phase};
}
const row='100\t1\tsignal\ttask\tready\n';
// Repeated recovery wakes share the same episode identity and doorbell.
{
  const f=fixture('no-row-to-no-row');
  fs.writeFileSync(f.marker,'announced:handling:first\n');
  const first=f.recovery('first');await f.journal.deliver(first);
  const repeated=f.recovery('first');
  assert.equal(repeated.id,first.id);
  await f.journal.deliver(repeated);
  const second=f.recovery('second');
  assert.equal(await f.journal.deliver(second),false);
  assert.equal(f.calls.length,1);
  assert.equal(f.journal.parked(second),true);
  assert.equal(f.reload().parked(second),true,'cap must survive plugin reload');
  // Unreadable or invalid state never proves retirement, even after TTL.
  const recordDir=f.queue.replace('/.wake-queue','/.opencode-v2-admissions');
  const firstPath=recordDir+'/'+fs.readdirSync(recordDir)[0]+'/'+first.id+'.json';
  fs.utimesSync(firstPath,1,1);fs.unlinkSync(f.marker);
  f.journal.pending();assert.equal(fs.existsSync(firstPath),true);
  fs.writeFileSync(f.marker,'invalid:handling:first\n');
  assert.equal(f.journal.parked(second),true);
  fs.writeFileSync(f.marker,'acked:handling:first\n');
  assert.equal(f.journal.acknowledged(first),true);
  // The next episode remains an obligation until it is admitted or acked.
  fs.writeFileSync(f.queue,'');
  fs.writeFileSync(f.marker,'announced:downtime:second\n');
  await f.reload().deliver(second);
  assert.equal(f.calls.length,2);assert.equal(f.calls[1].id,second.id);
  fs.writeFileSync(f.marker,'acked:downtime:second\n');
  assert.equal(f.reload().acknowledged(second),true);
}
// A row doorbell also covers a no-row recovery obligation.
for (const handled of [false,true]) {
  const f=fixture('row-to-no-row-'+handled);
  fs.writeFileSync(f.marker,'announced:handling:recovery\n');
  const prepared=f.journal.prepare('recovery','wake',{recovery:{generation:'recovery'}});
  fs.writeFileSync(f.queue,row);
  const first=f.journal.confirm(f.journal.prepare('first row'));await f.journal.deliver(first);
  // The earlier no-row preparation finishes successor confirmation after
  // another actionable close has already admitted a row-bearing doorbell.
  const later=f.journal.confirm(prepared,{generation:'recovery'});
  assert.equal(await f.journal.deliver(later),false);
  fs.writeFileSync(f.queue,'');
  if(handled)fs.writeFileSync(f.marker,'acked:handling:recovery\n');
  await f.reload().deliver(later);
  assert.equal(f.calls.length,handled?1:2);
  assert.equal(f.phase(later),handled?'acknowledged':'admitted');
  assert.equal(f.reload().pending().length,0,'a parked recovery must retire or admit after handling');
}
// An unacked successor generation keeps the admitted recovery doorbell
// outstanding: its drain presents current state and prints the later ack.
{
  const f=fixture('generation-unacked');
  fs.writeFileSync(f.marker,'announced:handling:first\n');
  const first=f.recovery('first');await f.journal.deliver(first);
  fs.writeFileSync(f.marker,'pending:downtime:second\n');
  assert.equal(f.reload().acknowledged(first),false);
  const second=f.recovery('second');
  assert.equal(await f.reload().deliver(second),false,'an unacked successor generation must not steer a second doorbell');
  fs.writeFileSync(f.marker,'announced:downtime:third\n');
  assert.equal(f.reload().acknowledged(first),false,'the first doorbell stays outstanding across generations');
  const third=f.recovery('third');
  assert.equal(await f.reload().deliver(third),false);
  assert.equal(f.reload().pending().length,2);
  assert.equal(f.calls.length,1);
  fs.writeFileSync(f.marker,'acked:downtime:third\n');
  const after=f.reload();
  assert.deepEqual(after.pending().map(value=>value.id),[second.id],'only the superseded unacked generation remains journaled');
  assert.equal(after.acknowledged(first),true);assert.equal(after.acknowledged(third),true);
  assert.equal(await after.deliver(third),true);assert.equal(after.parked(second),false);
  assert.equal(f.calls.length,1,'a later-generation ack retires the outstanding doorbell and its own episode without another admission');
}
// A doorbell admitted by an older claim never blocks the new owner.
{
  const f=fixture('claim-change');
  const recovery=(journal,generation)=>journal.confirm(journal.prepare('drain only','wake',{recovery:{generation}}),{generation});
  fs.writeFileSync(f.marker,'pending:handling:first\n');
  const previous=f.reload('claim-a');
  await previous.deliver(recovery(previous,'first'));
  fs.writeFileSync(f.marker,'pending:downtime:second\n');
  const owner=f.reload('claim-b');
  const second=recovery(owner,'second');
  assert.equal(f.reload('claim-a').parked(second),true);
  assert.equal(owner.parked(second),false);
  assert.equal(await owner.deliver(second),true);
  assert.equal(f.calls.length,2);assert.equal(f.calls[1].id,second.id);
  fs.writeFileSync(f.queue,row);
  const later=owner.confirm(owner.prepare('later row'));
  assert.equal(await f.reload('claim-b').deliver(later),false,'the new owner keeps its own one-doorbell cap');
  assert.equal(f.calls.length,2);
}
// A recorded drain handles an admitted row doorbell even while its rows stay
// queued. A parked wake stalls only when a recorded drain cannot be proven to
// precede its blocker's admission; an undrained blocker is coalescing.
for (const forced of [false,true]) {
  const f=fixture('drain-stall-'+forced);
  const drained=f.queue.replace('/.wake-queue','/.wake-drain-presented');
  fs.writeFileSync(drained,'1\tG\n');
  fs.writeFileSync(f.queue,row);
  const first=f.journal.confirm(f.journal.prepare('first row'));await f.journal.deliver(first);
  fs.writeFileSync(f.queue,row+'101\t2\tsignal\ttask\tnext\n');
  const later=f.journal.confirm(f.journal.prepare('later row'));
  assert.equal(await f.journal.deliver(later),false);
  assert.equal(f.journal.stalled(later),false,'an undrained blocker is healthy coalescing');
  if(forced){
    const path=f.queue.replace('/.wake-queue','/.opencode-v2-admissions/')+fs.readdirSync(f.queue.replace('/.wake-queue','/.opencode-v2-admissions'))[0]+'/'+first.id+'.json';
    const {drain,...legacy}=JSON.parse(fs.readFileSync(path,'utf8'));fs.writeFileSync(path,JSON.stringify(legacy));
  }
  fs.writeFileSync(drained,'2\tG\n');
  assert.equal(f.reload().parked(later),forced);
  assert.equal(f.reload().stalled(later),forced,'a drain after the blocker admission must expose a still-parked wake');
  await f.reload().deliver(later);
  assert.equal(f.calls.length,forced?1:2);
  assert.equal(fs.readFileSync(f.queue,'utf8'),row+'101\t2\tsignal\ttask\tnext\n','drain retirement never consumes rows');
}
// An in-flight no-row admission owns the slot before its native receipt.
{
  let release;
  const receipt=new Promise(resolve=>{release=resolve;});
  const f=fixture('inflight-recovery',()=>receipt);
  fs.writeFileSync(f.marker,'pending:handling:inflight\n');
  const first=f.recovery('inflight'),delivery=f.journal.deliver(first);
  fs.writeFileSync(f.queue,row);
  const later=f.journal.confirm(f.journal.prepare('concurrent row'));
  assert.equal(await f.journal.deliver(later),false);
  assert.equal(f.calls.length,1);
  release();await delivery;
  assert.equal(await f.journal.deliver(later),false,'receipt alone must not release the slot');
  fs.writeFileSync(f.marker,'acked:handling:inflight\n');
  await f.journal.deliver(later);
  assert.equal(f.calls.length,2);assert.equal(f.calls[1].id,later.id);
}
// A steer may finish canonical recovery handling before its receipt arrives.
{
  const f=fixture('lost-recovery-receipt',({marker})=>{
    fs.writeFileSync(marker,'acked:handling:lost\n');
    throw new Error('receipt lost after no-row handling');
  });
  fs.writeFileSync(f.marker,'pending:handling:lost\n');
  const first=f.recovery('lost');
  assert.equal(await f.journal.deliver(first),true);
  assert.equal(f.calls.length,1);assert.equal(f.phase(first),'acknowledged');
  assert.equal(f.reload().pending().length,0);
}
console.log('no-row/row doorbells share one steer cap per claim; canonical ack of the episode or a later generation releases parked obligations without consuming rows');
JS
  ) || fail "$out"
  pass "$out"
}

# Through the real coordinator and the real canonical drain/ack: a no-row
# recovery doorbell holds later wakes until the lead's drain runs after it was
# admitted, then rows arriving after that drain get their own doorbell, and
# superseded recoveries the drain presented never replay.
test_recovery_doorbell_retires_on_real_drain() {
  local scenario out lab
  for scenario in mid-turn-row coalesced-row superseded-recoveries; do
    lab="$TMP_ROOT/real-drain-$scenario"
    mkdir -p "$lab/bin" "$lab/state" "$lab/config"
    : > "$lab/state/.wake-queue"
    printf 'pending:downtime:G1\n' > "$lab/state/.watcher-down"
    : > "$lab/state/task.meta"
    cat > "$lab/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
s=$FM_STATE_OVERRIDE
if [ "${1:-}" = --handling-delivered ]; then
  case "$(cat "$s/.watcher-down")" in pending:*:"$2"|announced:*:"$2") exit 0 ;; *) exit 1 ;; esac
fi
marker=$(cat "$s/.watcher-down")
echo "watcher: started pid=$$ recovery-generation=${marker##*:}"
trap 'exit 0' TERM
while :; do
  if [ -f "$s/fire" ]; then cat "$s/fire"; rm -f "$s/fire"; exit 0; fi
  sleep 0.05
done
SH
    chmod +x "$lab/bin/fm-watch-arm.sh"
    cp "$CODE_ROOT/bin/fm-operational-input.sh" "$lab/bin/fm-operational-input.sh"
    out=$(SCENARIO="$scenario" CODE_ROOT="$CODE_ROOT" DRAIN="$DRAIN" LAB="$lab" node --input-type=module 2>&1 <<'JS'
import fs from 'node:fs';import assert from 'node:assert/strict';import {spawnSync} from 'node:child_process';import {pathToFileURL} from 'node:url';
const root=pathToFileURL(process.env.CODE_ROOT+'/');
const {createWatchArmCoordinator}=await import(new URL('.opencode/plugins/lib/fm-watch-arm-v2.js',root));
const {createAdmissionJournal}=await import(new URL('.opencode/plugins/fm-native-v2/admission.js',root));
const p={root:process.env.LAB,home:process.env.LAB,state:process.env.LAB+'/state',config:process.env.LAB+'/config'};
const queue=p.state+'/.wake-queue',marker=p.state+'/.watcher-down',scenario=process.env.SCENARIO;
const row='100\t2\tsignal\ttask\tsecond\n';
const admitted=[],failures=[];
const journal=createAdmissionJournal(p,'ses_drain',async input=>{assert.equal(input.delivery,'steer');admitted.push(input.id);return{id:input.id};},()=>{},{claim:'claim'});
const c=createWatchArmCoordinator(p,()=>{throw new Error('unjournaled delivery');},{owns:()=>true,admission:journal,failure:reason=>failures.push(reason)});
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const until=async(predicate,what)=>{for(let i=0;i<200&&!predicate();i++)await sleep(25);assert.ok(predicate(),what+' '+JSON.stringify(failures));};
const records=()=>fs.readdirSync(p.state+'/.opencode-v2-admissions',{recursive:true}).filter(name=>name.endsWith('.json')).length;
const fire=async(reason,count)=>{fs.writeFileSync(p.state+'/fire',reason+'\n');await until(()=>!fs.existsSync(p.state+'/fire')&&records()===count,'fire was not journaled');await sleep(400);};
const lead=(...args)=>{const r=spawnSync(process.env.DRAIN,args,{encoding:'utf8',env:{...process.env,FM_HOME:process.env.LAB,FM_STATE_OVERRIDE:p.state}});assert.equal(r.status,0,r.stderr);return r;};
const ack=drain=>{const m=drain.stderr.match(/--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)/);assert.ok(m,drain.stderr);return lead('--ack-through',m[1],'--recovery-generation',m[2]);};
const reconcile=async()=>{for(let tick=0;tick<3;tick++)await c.resumePending('ses_drain');};
try {
  assert.equal(await c.ensureArmed('ses_drain'),'armed');
  await fire('check: rearm-resurface',1);
  assert.equal(admitted.length,1,'G1 recovery was not admitted');
  if (scenario==='mid-turn-row') {
    // The lead drains the recovery at turn start; r2 arrives mid-turn.
    const drain=lead();
    fs.appendFileSync(queue,row);
    await fire('signal: task second',2);
    assert.equal(admitted.length,2,'a row arriving after the drain was stranded behind the handled recovery');
    ack(drain);
    assert.equal(fs.readFileSync(queue,'utf8'),row,'the printed recovery ack never consumes later rows');
    assert.match(fs.readFileSync(marker,'utf8'),/^pending:/);
    await reconcile();
    assert.equal(admitted.length,2);
    assert.equal(journal.pending().length,0);
  } else if (scenario==='coalesced-row') {
    // r2 arrives before the lead drains: it coalesces into the G1 doorbell.
    fs.appendFileSync(queue,row);
    await fire('signal: task second',2);
    await reconcile();
    assert.equal(admitted.length,1,'an undrained recovery doorbell let a second doorbell stack');
    assert.equal(journal.pending().length,1);
    const drain=lead();
    assert.match(drain.stdout,/second/);
    ack(drain);
    await reconcile();
    assert.equal(admitted.length,1,'the drain presented and acked r2; no extra doorbell');
    assert.equal(journal.pending().length,0);
  } else {
    // G2 and G3 park behind G1; the lead's drain presents G3 and acks it.
    fs.writeFileSync(marker,'pending:downtime:G2\n');
    await fire('check: rearm-resurface',2);
    fs.writeFileSync(marker,'pending:downtime:G3\n');
    await fire('check: rearm-resurface',3);
    await reconcile();
    assert.equal(admitted.length,1,'superseded recoveries stacked doorbells');
    const drain=lead();
    assert.match(drain.stderr,/--recovery-generation G3/);
    ack(drain);
    assert.equal(fs.readFileSync(marker,'utf8'),'acked:handling:G3\n');
    await reconcile();
    assert.equal(admitted.length,1,'a covered recovery replayed after the later drain/ack');
    assert.equal(journal.pending().length,0,'a covered recovery obligation remained');
  }
  assert.deepEqual(failures,[]);
} finally { await c.cleanup(); }
console.log('real drain/ack '+scenario+': recovery doorbell coalesces until drained; later rows admit; covered recoveries retire');
JS
    ) || fail "$out"
    pass "$out"
  done
}

# Through the real coordinator: the lead drains W1{r1} early in a long turn, r2
# fires a successor whose wake parks behind W1, then the lead acks r1 and G1.
# The parked wake must not confirm handling while parked, and once released it
# must admit r2 instead of re-confirming the already acked generation.
test_parked_row_wake_admits_after_partial_canonical_ack() {
  local out lab="$TMP_ROOT/partial-ack"
  mkdir -p "$lab/bin" "$lab/state" "$lab/config"
  printf '100\t1\tsignal\ttask\tfirst\n' > "$lab/state/.wake-queue"
  printf 'pending:handling:G1\n' > "$lab/state/.watcher-down"
  : > "$lab/state/task.meta"
  cat > "$lab/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
s=$FM_STATE_OVERRIDE
if [ "${1:-}" = --handling-delivered ]; then
  echo "$2" >> "$s/confirms"
  case "$(cat "$s/.watcher-down")" in pending:*:"$2"|announced:*:"$2") exit 0 ;; *) exit 1 ;; esac
fi
if [ ! -f "$s/first" ]; then
  touch "$s/first"
  echo 'signal: task first'
  exit 0
fi
echo "watcher: started pid=$$ recovery-generation=G1"
trap 'exit 0' TERM
while :; do
  if [ -f "$s/fire" ]; then rm -f "$s/fire"; echo 'signal: task second'; exit 0; fi
  sleep 0.05
done
SH
  chmod +x "$lab/bin/fm-watch-arm.sh"
  cp "$CODE_ROOT/bin/fm-operational-input.sh" "$lab/bin/fm-operational-input.sh"
  out=$(CODE_ROOT="$CODE_ROOT" LAB="$lab" node --input-type=module 2>&1 <<'JS'
import fs from 'node:fs';import assert from 'node:assert/strict';import {pathToFileURL} from 'node:url';
const root=pathToFileURL(process.env.CODE_ROOT+'/');
const {createWatchArmCoordinator}=await import(new URL('.opencode/plugins/lib/fm-watch-arm-v2.js',root));
const {createAdmissionJournal}=await import(new URL('.opencode/plugins/fm-native-v2/admission.js',root));
const p={root:process.env.LAB,home:process.env.LAB,state:process.env.LAB+'/state',config:process.env.LAB+'/config'};
const queue=p.state+'/.wake-queue',marker=p.state+'/.watcher-down',confirms=()=>{try{return fs.readFileSync(p.state+'/confirms','utf8').trim().split('\n').length;}catch{return 0;}};
const admitted=[],failures=[];
const journal=createAdmissionJournal(p,'ses_partial',async input=>{assert.equal(input.delivery,'steer');admitted.push(input.id);return{id:input.id};});
const c=createWatchArmCoordinator(p,()=>{throw new Error('unjournaled delivery');},{owns:()=>true,admission:journal,failure:reason=>failures.push(reason)});
const until=async(predicate,what)=>{for(let i=0;i<200&&!predicate();i++)await new Promise(resolve=>setTimeout(resolve,25));assert.ok(predicate(),what+' '+JSON.stringify(failures));};
try {
  await c.ensureArmed('ses_partial');
  await until(()=>admitted.length===1,'W1 was not admitted');
  assert.equal(confirms(),1);
  // The lead drained r1 at turn start; r2 arrives mid-turn and fires again.
  fs.appendFileSync(queue,'101\t2\tsignal\ttask\tsecond\n');
  fs.writeFileSync(p.state+'/fire','');
  await until(()=>!fs.existsSync(p.state+'/fire')&&journal.pending().length===1,'W2 was not journaled');
  for(let tick=0;tick<3;tick++)await c.resumePending('ses_partial');
  await new Promise(resolve=>setTimeout(resolve,300));
  assert.equal(admitted.length,1,'W2 must park behind the undrained W1');
  assert.equal(journal.parked(journal.pending()[0]),true);
  assert.equal(confirms(),1,'a parked wake must not confirm handling on reconciliation');
  // The lead acks only r1 and the recovery generation.
  fs.writeFileSync(queue,'101\t2\tsignal\ttask\tsecond\n');
  fs.writeFileSync(marker,'acked:handling:G1\n');
  await c.resumePending('ses_partial');
  assert.equal(admitted.length,2,'the released wake for r2 was stranded: '+JSON.stringify(failures));
  assert.equal(journal.pending().length,0);
  assert.equal(confirms(),1,'an acked episode must not be re-confirmed');
  assert.deepEqual(failures,[]);
  assert.equal(fs.readFileSync(queue,'utf8'),'101\t2\tsignal\ttask\tsecond\n','admission never consumes rows');
} finally { await c.cleanup(); }
console.log('coordinator parks W2 without handoff work and admits r2 after a partial canonical ack');
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
  test_recovery_doorbells_share_the_outstanding_cap \
  test_parked_row_wake_admits_after_partial_canonical_ack \
  test_recovery_doorbell_retires_on_real_drain \
  test_handoff_before_lead_ack_is_accepted \
  test_handoff_after_lead_ack_is_rejected; do
  ( "$t" ) || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] || { printf 'not ok - %s wake admission case(s) failed\n' "$FAILED" >&2; exit 1; }
