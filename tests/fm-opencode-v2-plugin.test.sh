#!/usr/bin/env bash
# Credential-free behavioral coverage for the native exact-session contract.
# Live native loader/service/Herdr qualification is separate and opt-in.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-plugin)
export NODE_NO_WARNINGS=1
export FM_V2_REGISTRY_NAMESPACE="test-$$-$RANDOM"

test_native_exact_owner_and_transport() {
  local out
  out=$(ROOT="$ROOT" LAB="$TMP_ROOT" node --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const base=pathToFileURL(process.env.ROOT+'/');
const owner=await import(new URL('bin/fm-opencode-v2-owner.mjs',base));
const server=await import(new URL('.opencode/plugins/fm-native-v2/server.js',base));
const tui=await import(new URL('.opencode/plugins/fm-native-v2/tui.js',base));
const {runProcess}=await import(new URL('.opencode/plugins/lib/fm-plugin-common.js',base));
const {createAdmissionJournal}=await import(new URL('.opencode/plugins/fm-native-v2/admission.js',base));
const {createSessionBinder}=await import(new URL('.opencode/plugins/lib/fm-session-bind-v2.js',base));
const home=process.env.LAB+'/external';
fs.mkdirSync(home+'/state',{recursive:true,mode:0o700});
fs.mkdirSync(home+'/config',{recursive:true,mode:0o700});
const me=owner.identity(process.pid);
const r={version:1,sessionID:'ses_native_exact',claimID:'a'.repeat(48),root:process.env.ROOT,home,state:home+'/state',config:home+'/config',ownerPID:me.pid,ownerStart:me.start,hostBootID:me.boot,servicePID:me.pid,serviceStart:me.start,lifecycle:'claimed'};
let metadata={kept:'value'};
const get=async({sessionID})=>({id:sessionID,location:{directory:r.root},metadata:sessionID===r.sessionID?metadata:{}});
const ctx={client:{session:{get,update:async input=>{metadata=input.metadata;},environment:async input=>{assert.equal(input.variables.FM_HOME,home);}},server:{info:async()=>({pid:me.pid})},rpc:()=>({bindingStatus:input=>server.bindingStatus({get},input)})}};
await tui.activate(ctx,r);
await tui.rebind(ctx,r);
assert.equal(tui.helperEnvironment(r).PATH,process.env.PATH);
assert.equal(tui.helperEnvironment(r).HOME,process.env.HOME);
assert.equal(tui.helperEnvironment(r).FM_V2_ACTIVATION,undefined);
assert.equal(tui.helperEnvironment(r).OPENCODE_PASSWORD,undefined);
const killed=await runProcess(process.execPath,['-e','setInterval(()=>{},1000)'],{timeout:50});
assert.notEqual(killed.code,0);
assert.equal(killed.signal,'SIGTERM');
assert.equal(metadata.kept,'value');
assert.equal((await server.bindingStatus({get},{sessionID:r.sessionID,claimID:r.claimID})).status,'valid');
assert.equal((await server.guardScope({get},'ses_unrelated')).registered,false);
assert.equal((await server.guardScope({get:async()=>({id:'ses_child',parentID:r.sessionID,location:{directory:r.root},metadata})},'ses_child')).registered,false);
// Same-directory root event is never implicit authority (round-one red case).
const binder=createSessionBinder({location:{directory:r.root},session:{get}});
await binder.observe({type:'session.created',data:{sessionID:'ses_unrelated',location:{directory:r.root}}});
assert.equal(await binder.owns('ses_unrelated'),false);
// Refused takeover must not rewrite either canonical view or native metadata.
await assert.rejects(tui.activate(ctx,{...r,claimID:'b'.repeat(48)}));
assert.equal(metadata.firstmateV2Lead.claimID,r.claimID);
assert.equal(owner.readRegistration(r.sessionID).claimID,r.claimID);
assert.throws(()=>owner.publish('claim',{...r,config:home+'/replacement'}),/frozen/);
fs.writeFileSync(r.state+'/.lock',String(me.pid)+'\n',{mode:0o600});
const env={...process.env,FM_HOME:home,FM_ROOT_OVERRIDE:r.root,FM_STATE_OVERRIDE:r.state,FM_CONFIG_OVERRIDE:r.config,OPENCODE_SESSION_ID:r.sessionID};
const check=(variables=env)=>spawnSync('bash',['-c','. "$1/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$FM_STATE_OVERRIDE"','check',r.root],{env:variables});
assert.equal(check().status,0);
assert.notEqual(check({...env,FM_CONFIG_OVERRIDE:home+'/wrong'}).status,0);
assert.notEqual(check({...env,OPENCODE_SESSION_ID:'ses_unrelated'}).status,0);
assert.notEqual(check({...env,FM_HOME:r.root}).status,0);
// Missing helper is denial only for the exact lead, not unrelated/child calls.
assert.equal(await server.denyReason({get},{tool:'shell',sessionID:'ses_unrelated',input:{command:'true'}}),'');
assert.equal(await server.denyReason({get},{tool:'shell',sessionID:r.sessionID,input:{command:'true'}}),'');
assert.match(await server.denyReason({get},{tool:'shell',sessionID:r.sessionID,input:{command:'cd /'}}),/persistent-cd/);
assert.match(await server.denyReason({get},{tool:'shell',sessionID:r.sessionID,input:{command:'bin/fm-watch-arm.sh &'}}),/\[/);
// Service birth mismatch preserves protective refusal through restart.
owner.writePrivate(r.state+'/.opencode-v2-owner.json',{...r,serviceStart:'0'});
assert.notEqual(check().status,0);
assert.match((await server.guardScope({get},r.sessionID)).error,/stale/);
owner.writePrivate(r.state+'/.opencode-v2-owner.json',r);
const originalMetadata=metadata;
metadata={kept:'replacement'};
assert.equal((await server.guardScope({get},r.sessionID)).registered,true);
assert.match((await server.guardScope({get},r.sessionID)).error,/stale/);
metadata=originalMetadata;
owner.publish('retire',r);
assert.match((await server.guardScope({get},r.sessionID)).error,/stale/);
assert.equal((await server.guardScope({get},'ses_unrelated')).registered,false);
owner.publish('claim',r);
// Admission retries keep exact ID/text, preserve queue and survive reload.
fs.writeFileSync(r.state+'/.wake-queue','100\t1\tsignal\ttask\tready\n',{mode:0o600});
let calls=[];
const journal=createAdmissionJournal(r,r.sessionID,async input=>{calls.push(input);if(calls.length===1)throw new Error('unknown acknowledgement');return{id:input.id};},()=>{});
const admission=journal.prepare('original encoded wake');
await journal.deliver(journal.confirm(admission));
assert.equal(calls.length,2);
assert.deepEqual(calls[0],calls[1]);
assert.equal(calls[0].delivery,'queue');
assert.equal(journal.prepare('replacement must not change text').text,'original encoded wake');
assert.equal(fs.readFileSync(r.state+'/.wake-queue','utf8'),'100\t1\tsignal\ttask\tready\n');
fs.appendFileSync(r.state+'/.wake-queue','101\t2\tsignal\ttask\tsecond\n');
const failing=createAdmissionJournal(r,r.sessionID,async()=>{throw new Error('offline');},()=>{});
const saved=failing.prepare('second wake');
await assert.rejects(failing.deliver(failing.confirm(saved)));
assert.equal(failing.pending().length,1);
const reloaded=createAdmissionJournal(r,r.sessionID,async input=>{calls.push(input);return{id:input.id};},()=>{});
const pending=reloaded.pending()[0];
assert.equal(pending.id,saved.id);
await reloaded.deliver(pending);
assert.equal(reloaded.pending().length,0);
// The canonical ack owner, not this adapter, removes rows. An old pending
// transport is retired distinctly from admission after those rows disappear.
fs.appendFileSync(r.state+'/.wake-queue','102\t3\tcheck\tx\tthird\n');
const obsolete=reloaded.prepare('third original wake');
fs.writeFileSync(r.state+'/.wake-queue','');
assert.equal(reloaded.pending().length,0);
assert.equal(reloaded.acknowledged(obsolete),true);
const namespace=process.env.FM_V2_REGISTRY_NAMESPACE;
process.env.FM_V2_REGISTRY_NAMESPACE='../unsafe';
assert.equal((await server.guardScope({get},'ses_unrelated')).registered,false);
assert.equal((await server.guardScope({get},r.sessionID)).registered,true);
process.env.FM_V2_REGISTRY_NAMESPACE=namespace;
// Filesystem attacks are errors, never authority.
const bad=home+'/bad.json';
fs.symlinkSync(r.state+'/.opencode-v2-owner.json',bad);
assert.throws(()=>owner.readPrivate(bad));
fs.unlinkSync(bad);
fs.linkSync(r.state+'/.opencode-v2-owner.json',bad);
assert.throws(()=>owner.readPrivate(bad));
fs.unlinkSync(bad);
owner.publish('retire',r);
owner.publish('cleanup-test-namespace',{});
console.log('exact owner/guard/transport behaviors passed');
JS
  ) || { fail "native exact-owner contract: $out"; return; }
  pass "$out"
}

test_v1_factories_preserved() {
  local out
  out=$(ROOT="$ROOT" node --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
for(const [name,factory] of [['watch-arm','FmPrimaryWatchArm'],['turnend-guard','FmPrimaryTurnendGuard'],['sessionstart-nudge','FmPrimarySessionstartNudge'],['cd-check','FmPrimaryCdCheck'],['pretool-check','FmPrimaryPretoolCheck']]){
  const module=await import(pathToFileURL(process.env.ROOT+'/.opencode/plugins/fm-primary-'+name+'.js'));
  assert.equal(typeof module[factory],'function');
  assert.equal(await module.default.setup(new Proxy({},{get(){throw new Error('compatibility entry used a native API');}})),undefined);
  assert.equal(module.default.effect,undefined);
}
console.log('V1 factories preserved; competing V2 entrypoints removed');
JS
  ) || { fail "$out"; return; }
  pass "$out"
}

test_coordinator_persists_before_handoff() {
  local out lab="$TMP_ROOT/coordinator"
  mkdir -p "$lab/bin" "$lab/state" "$lab/config"
  printf '100\t1\tsignal\ttask\tready\n' > "$lab/state/.wake-queue"
  : > "$lab/state/task.meta"
  cat > "$lab/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  [ -n "$(find "$FM_STATE_OVERRIDE/.opencode-v2-admissions" -name 'msg_*.json' -print -quit)" ] || exit 1
  [ "$(cat "$FM_STATE_OVERRIDE/arm-pid")" = "$4" ] || exit 1
  echo confirmed >> "$FM_STATE_OVERRIDE/order"
  exit 0
fi
if [ ! -f "$FM_STATE_OVERRIDE/first" ]; then
  touch "$FM_STATE_OVERRIDE/first"
  echo 'signal: task ready'
  exit 0
fi
echo $$ > "$FM_STATE_OVERRIDE/arm-pid"
echo "watcher: started pid=$$ recovery-generation=fixture-generation"
trap 'exit 0' TERM
while :; do sleep 0.05; done
SH
  chmod +x "$lab/bin/fm-watch-arm.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$lab/bin/fm-operational-input.sh"
  out=$(ROOT="$ROOT" LAB="$lab" node --input-type=module 2>&1 <<'JS'
import fs from 'node:fs';import assert from 'node:assert/strict';import {pathToFileURL} from 'node:url';
const root=pathToFileURL(process.env.ROOT+'/');
const {createWatchArmCoordinator}=await import(new URL('.opencode/plugins/lib/fm-watch-arm-v2.js',root));
const {createAdmissionJournal}=await import(new URL('.opencode/plugins/fm-native-v2/admission.js',root));
const p={root:process.env.LAB,home:process.env.LAB,state:process.env.LAB+'/state',config:process.env.LAB+'/config'};
let admitted=false,failures=[];
const journal=createAdmissionJournal(p,'ses_coordinator',async input=>{
  assert.equal(fs.readFileSync(p.state+'/order','utf8').trim(),'confirmed');
  fs.appendFileSync(p.state+'/order','admitted\n');admitted=true;return{id:input.id};
});
const c=createWatchArmCoordinator(p,()=>{throw new Error('unpersisted admission');},{owns:()=>true,admission:journal,failure:reason=>failures.push(reason)});
await c.ensureArmed('ses_coordinator');
for(let i=0;i<100&&!admitted;i++)await new Promise(resolve=>setTimeout(resolve,20));
assert.equal(admitted,true,JSON.stringify(failures));
assert.equal(fs.readFileSync(p.state+'/order','utf8'),'confirmed\nadmitted\n');
const pid=Number(fs.readFileSync(p.state+'/arm-pid','utf8'));
await c.cleanup();
assert.throws(()=>process.kill(pid,0));
assert.equal(fs.readFileSync(p.state+'/.wake-queue','utf8'),'100\t1\tsignal\ttask\tready\n');
console.log('persistent admission precedes handoff; confirmation precedes delivery; cleanup retires child');
JS
  ) || { fail "$out"; return; }
  pass "$out"
}

test_native_exact_owner_and_transport
test_v1_factories_preserved
test_coordinator_persists_before_handoff
