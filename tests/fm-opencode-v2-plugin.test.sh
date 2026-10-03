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
const r={version:1,sessionID:'ses_native_exact',claimID:'a'.repeat(48),root:process.env.ROOT,home,state:home+'/state',config:home+'/config',ownerPID:me.pid,ownerStart:me.start,hostBootID:me.boot,servicePID:me.pid,serviceStart:me.start,serviceURL:'http://127.0.0.1:12345',lifecycle:'claimed'};
assert.equal(await tui.supervisionNeeded(r),false);
fs.writeFileSync(r.state+'/fixture.check.sh','');
fs.writeFileSync(r.state+'/fixture.check-trust','');
assert.equal(await tui.supervisionNeeded(r),true);
fs.unlinkSync(r.state+'/fixture.check.sh');fs.unlinkSync(r.state+'/fixture.check-trust');
fs.mkdirSync(r.state+'/procevent');fs.writeFileSync(r.state+'/procevent/fixture.source','');
assert.equal(await tui.supervisionNeeded(r),true);
fs.unlinkSync(r.state+'/procevent/fixture.source');
let metadata={kept:'value'};
const get=async({sessionID})=>({id:sessionID,location:{directory:r.root},metadata:sessionID===r.sessionID?metadata:{}});
const ctx={client:{session:{get,update:async input=>{metadata=input.metadata;},environment:async input=>{assert.equal(input.variables.FM_HOME,home);}},server:{info:async()=>({pid:me.pid})},rpc:()=>({bindingStatus:input=>server.bindingStatus({get},input)})}};
await tui.activate(ctx,r);
fs.mkdirSync(home+'/native',{mode:0o700});fs.mkdirSync(home+'/bin',{mode:0o700});
owner.writePrivate(home+'/native/service.json',{pid:me.pid,url:r.serviceURL,password:'fixture'});
fs.writeFileSync(home+'/bin/shuvcode',`#!/bin/bash\nprintf 'state %s\\n' '${home}/native'\n`,{mode:0o700});
process.env.PATH=home+'/bin:'+process.env.PATH;
await tui.rebind(ctx,r);
await assert.rejects(tui.rebind(ctx,{...r,serviceURL:'http://127.0.0.1:9999'}),/immutable/);
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
const confirmed=failing.confirm(saved);
const journalPath=r.state+'/.opencode-v2-admissions/';
const savedPath=journalPath+fs.readdirSync(journalPath,{recursive:true}).find(name=>name.endsWith(saved.id+'.json'));
fs.utimesSync(savedPath,1,1);
failing.confirm(confirmed);
assert.equal(fs.statSync(savedPath).mtimeMs,1000);
await assert.rejects(failing.deliver(confirmed));
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
const obsoletePath=journalPath+fs.readdirSync(journalPath,{recursive:true}).find(name=>name.endsWith(obsolete.id+'.json'));
fs.utimesSync(obsoletePath,1,1);reloaded.pending();assert.equal(fs.existsSync(obsoletePath),false);
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
  ) || fail "native exact-owner contract: $out"
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
  ) || fail "$out"
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
  ) || fail "$out"
  pass "$out"
}

test_native_exact_owner_and_transport
test_v1_factories_preserved
test_coordinator_persists_before_handoff

test_frozen_endpoint_and_worker_execution() {
  local out
  out=$(ROOT="$ROOT" LAB="$TMP_ROOT/endpoint" node --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';import fs from 'node:fs';import {spawn,spawnSync} from 'node:child_process';import {pathToFileURL} from 'node:url';
const root=process.env.ROOT,lab=process.env.LAB;
fs.mkdirSync(lab+'/bin',{recursive:true});fs.mkdirSync(lab+'/native',{recursive:true});fs.mkdirSync(lab+'/home/state',{recursive:true});fs.mkdirSync(lab+'/home/config',{recursive:true});
const owner=await import(pathToFileURL(root+'/bin/fm-opencode-v2-owner.mjs'));
const session=await import(pathToFileURL(root+'/bin/fm-opencode-v2-session.mjs'));
const me=owner.identity(process.pid),endpoint='http://127.0.0.1:23456';
process.env.FM_V2_REGISTRY_NAMESPACE='test-endpoint-'+process.pid;
process.env.FIXTURE_STATE=lab+'/native';process.env.FIXTURE_PID=String(process.pid);process.env.FIXTURE_ROOT=root;process.env.FIXTURE_LOG=lab+'/api.log';process.env.FIXTURE_ACTIVE=lab+'/active';
fs.writeFileSync(lab+'/native/service.json',JSON.stringify({pid:me.pid,url:endpoint,password:'private-fixture'}),{mode:0o600});
fs.writeFileSync(lab+'/bin/shuvcode',`#!/usr/bin/env node
const fs=require('fs'),a=process.argv.slice(2),e=process.env;
if(a[0]==='debug'){console.log('state '+e.FIXTURE_STATE);process.exit(0)}
if(a[0]!=='api'||a[1]!=='--server'||a[2]!=='${endpoint}'||e.OPENCODE_PASSWORD!=='private-fixture')process.exit(90);
const op=a[3];fs.appendFileSync(e.FIXTURE_LOG,op+'\\n');
const sid='ses_endpoint';
if(op==='server.info')console.log(JSON.stringify({pid:Number(e.FIXTURE_PID)}));
else if(op==='shell.list')console.log(JSON.stringify({data:[{pid:Number(e.FIXTURE_SHELL_PID),status:'running',cwd:e.FIXTURE_CWD||e.FIXTURE_ROOT,command:'fixture model tool',metadata:{sessionID:e.FIXTURE_META||sid}}]}));
else if(op==='session.get')console.log(JSON.stringify({data:{id:e.FIXTURE_WRONG||sid,location:{directory:e.FIXTURE_ROOT},model:{providerID:'fixture',id:'echo'}}}));
else if(op==='session.active')console.log(JSON.stringify({data:fs.existsSync(e.FIXTURE_ACTIVE)?{[sid]:{type:'running'}}:{}}));
 else if(op==='session.interrupt'){if(!a.includes('sessionID='+sid)||!a.includes('resume=false'))process.exit(91);fs.rmSync(e.FIXTURE_ACTIVE,{force:true});console.log(JSON.stringify({interrupted:e.FIXTURE_IDLE_INTERRUPT!=='1'}))}
else process.exit(92);
`,{mode:0o700});
process.env.PATH=lab+'/bin:'+process.env.PATH;
const partial={version:1,sessionID:'ses_endpoint',claimID:'d'.repeat(48),root,home:lab+'/home',state:lab+'/home/state',config:lab+'/home/config',servicePID:me.pid,serviceStart:me.start,hostBootID:me.boot,serviceURL:endpoint,lifecycle:'claimed'};
const child=spawn(process.execPath,['--input-type=module','-e',`import * as o from ${JSON.stringify(pathToFileURL(root+'/bin/fm-opencode-v2-owner.mjs').href)};const me=o.identity(process.pid);const r={...JSON.parse(process.env.RECORD),ownerPID:me.pid,ownerStart:me.start};o.publish('claim',r);console.log(JSON.stringify(r));setInterval(()=>{},10000);`],{env:{...process.env,RECORD:JSON.stringify(partial)},stdio:['ignore','pipe','pipe']});
let r;
try {
 r=await new Promise((resolve,reject)=>{let text='';child.stdout.on('data',c=>{text+=c;if(text.includes('\n'))resolve(JSON.parse(text.trim()))});child.on('exit',()=>reject(new Error('owner fixture exited')));child.stderr.on('data',c=>reject(new Error(String(c))));});
 fs.writeFileSync(r.state+'/.lock',String(r.ownerPID),{mode:0o600});
 const env={...process.env,FM_HOME:r.home,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:r.state,FM_CONFIG_OVERRIDE:r.config,OPENCODE_SESSION_ID:r.sessionID};
 const helper=(extra={})=>spawnSync('bash',['-c','export FIXTURE_SHELL_PID=$$; node "$1/bin/fm-opencode-v2-owner.mjs" helper "$FM_STATE_OVERRIDE"','fixture',root],{encoding:'utf8',env:{...env,...extra}});
 assert.equal(helper().status,0);
 assert.notEqual(helper({FIXTURE_CWD:lab}).status,0);
 assert.notEqual(helper({FIXTURE_META:'ses_worker'}).status,0);
 assert.throws(()=>owner.registeredService('http://127.0.0.1:9999'),/unregistered/);
 const primary=spawnSync(root+'/bin/fm-opencode-v2-primary.sh',['--session',r.sessionID,'--native-binary','/bin/true','--server','http://127.0.0.1:9999'],{encoding:'utf8',env:{...env,FM_HOME:r.home}});
 assert.notEqual(primary.status,0);assert.match(primary.stderr,/unregistered/);
 assert.throws(()=>owner.nativeAPI({...r,serviceURL:undefined},'server.info'),/endpoint/);
 assert.throws(()=>owner.schema({...r,serviceURL:'http://user:secret@127.0.0.1:23456'}),/endpoint/);
 assert.equal(owner.registeredService(endpoint).serviceURL,endpoint);
 const defaultPrimary=spawnSync(root+'/bin/fm-opencode-v2-primary.sh',['--session',r.sessionID,'--native-binary','/bin/echo'],{encoding:'utf8',env:{...env,FM_HOME:r.home}});
 assert.equal(defaultPrimary.status,0,defaultPrimary.stderr);assert.equal(defaultPrimary.stdout.trim(),'--server '+endpoint+' --session '+r.sessionID);
 const beforeRefusal=fs.readFileSync(process.env.FIXTURE_LOG,'utf8');
 fs.renameSync(lab+'/native/service.json',lab+'/native/retained.json');
 assert.throws(()=>owner.nativeAPI(r,'server.info'),/unregistered/);
 const unregisteredHelper=helper();assert.notEqual(unregisteredHelper.status,0);assert.match(unregisteredHelper.stderr,/unregistered/);
 assert.equal(fs.readFileSync(process.env.FIXTURE_LOG,'utf8'),beforeRefusal,'missing endpoint registration must not query/start another service');
 fs.renameSync(lab+'/native/retained.json',lab+'/native/service.json');
 assert.throws(()=>owner.publish('claim',{...r,serviceURL:'http://127.0.0.1:9999'}),/conflicting/);
 const worker=lab+'/worker.json';owner.writePrivate(worker,{version:1,sessionID:r.sessionID,location:{directory:root},model:{providerID:'fixture',id:'echo'},serviceURL:endpoint,servicePID:me.pid,serviceStart:me.start,hostBootID:me.boot});
 fs.writeFileSync(process.env.FIXTURE_ACTIVE,'running');
 assert.equal((await session.reconcileWorker('status',worker,root)).executing,true);
 await assert.rejects(session.reconcileWorker('teardown',worker,root),/still executing/);
 assert.equal((await session.reconcileWorker('interrupt',worker,root)).executing,false);
 assert.equal((await session.reconcileWorker('teardown',worker,root)).executing,false);
 fs.writeFileSync(process.env.FIXTURE_ACTIVE,'running');
 assert.equal((await session.reconcileWorker('discard',worker,root)).executing,false);
 process.env.FIXTURE_WRONG='ses_other';await assert.rejects(session.reconcileWorker('interrupt',worker,root),/identity/);delete process.env.FIXTURE_WRONG;
 // Drive lifecycle executables too: a dead pane cannot suppress native
 // cancellation, and executing work refuses cleanup before any return action.
 const work=lab+'/work',state=r.state,task='native-worker';fs.mkdirSync(work);
 process.env.FIXTURE_ROOT=work;
 owner.writePrivate(state+'/'+task+'.opencode-v2-session.json',{...owner.readPrivate(worker),location:{directory:work}});
 fs.writeFileSync(lab+'/bin/tmux','#!/bin/bash\nif [ "$1" = send-keys ]; then echo unsafe-pane-action >> "$FIXTURE_LOG"; fi\necho bash\n',{mode:0o700});
 fs.writeFileSync(lab+'/bin/treehouse','#!/bin/bash\necho unsafe-return >> "$FIXTURE_LOG"\nexit 1\n',{mode:0o700});
 fs.writeFileSync(r.config+'/backlog-backend','manual\n');fs.writeFileSync(state+'/.last-watcher-beat','');
 const meta=spawnSync('bash',['-c','. "$1/tests/lib.sh"; fm_write_meta "$2/native-worker.meta" "window=firstmate:fm-native-worker" "endpoint_task_id=native-worker" "backend=tmux" "harness=opencode-v2" "kind=ship" "mode=local-only" "spawn_gen=native-test" "worktree=$3" "project=$3"','fixture',root,state,work],{encoding:'utf8',env:process.env});
 assert.equal(meta.status,0,meta.stderr);
 const lifecycleEnv={...process.env,FM_HOME:r.home,FM_ROOT_OVERRIDE:root,FM_STATE_OVERRIDE:state,FM_CONFIG_OVERRIDE:r.config};delete lifecycleEnv.OPENCODE_SESSION_ID;
 fs.writeFileSync(process.env.FIXTURE_ACTIVE,'running');
 const refuse=spawnSync(root+'/bin/fm-teardown.sh',[task],{encoding:'utf8',env:lifecycleEnv});
 assert.notEqual(refuse.status,0);assert.match(refuse.stderr,/still executing/,refuse.stderr);assert.equal(fs.existsSync(work),true);
 const cancel=spawnSync(root+'/bin/fm-control.sh',[task,'interrupt'],{encoding:'utf8',env:lifecycleEnv});
 assert.equal(cancel.status,0,cancel.stderr);assert.match(cancel.stdout,/verified=native-session cancel=confirmed/);assert.equal(fs.existsSync(process.env.FIXTURE_ACTIVE),false);
 assert.doesNotMatch(fs.readFileSync(process.env.FIXTURE_LOG,'utf8'),/unsafe-pane-action|unsafe-return/);
 // Failed-launch lifecycle: real isolated git copies, actual launcher refusal,
 // no sidecar/prompt, then successful exact exit and ordinary/forced cleanup.
 const repo=lab+'/failed-project';
 const git=(...args)=>{const result=spawnSync('git',args,{encoding:'utf8'});assert.equal(result.status,0,result.stderr);};
 git('init','-q','-b','main',repo);git('-C',repo,'config','user.name','Fixture');git('-C',repo,'config','user.email','fixture@example.invalid');
 fs.writeFileSync(repo+'/README.md','fixture\n');git('-C',repo,'add','README.md');git('-C',repo,'commit','-qm','fixture base');
 fs.writeFileSync(lab+'/bin/treehouse','#!/bin/bash\nset -eu\n[ "$1" = return ] && [ "$2" = --force ] || exit 91\ngit worktree remove --force "$3"\n',{mode:0o700});
 fs.writeFileSync(lab+'/bin/tmux','#!/bin/bash\nif [ "$1" = list-windows ]; then echo "fm-$FIXTURE_TASK"; elif [ "$1" = send-keys ]; then echo unsafe-pane-action >> "$FIXTURE_LOG"; else echo bash; fi\n',{mode:0o700});
 for (const phase of ['absent-normal','absent-force','gone-force']) {
   const forced=phase!=='absent-normal',id='failed-'+phase,wt=lab+'/'+id,sidecar=state+'/'+id+'.opencode-v2-session.json';
   git('-C',repo,'worktree','add','-q','-b',id,wt);
   const meta=spawnSync('bash',['-c','. "$1/tests/lib.sh"; fm_write_meta "$2/$3.meta" "window=firstmate:fm-$3" "endpoint_task_id=$3" "backend=tmux" "harness=opencode-v2" "kind=ship" "mode=local-only" "spawn_gen=failed-launch-test" "worktree=$4" "project=$5"','fixture',root,state,id,wt,repo],{encoding:'utf8',env:process.env});assert.equal(meta.status,0,meta.stderr);
   const failedEnv={...lifecycleEnv,FIXTURE_TASK:id};
   const before=fs.readFileSync(process.env.FIXTURE_LOG,'utf8');
   const launch=spawnSync(root+'/bin/fm-opencode-v2-launch.sh',['--model','fixture/missing','--prompt','must not run','--session-record',sidecar],{cwd:wt,encoding:'utf8',env:lifecycleEnv});
   assert.notEqual(launch.status,0);assert.equal(fs.existsSync(sidecar),false);assert.doesNotMatch(fs.readFileSync(process.env.FIXTURE_LOG,'utf8').slice(before.length),/session.prompt/);
   fs.writeFileSync(state+'/'+id+'.status','failed: launch refused before prompt admission\n');
    if(phase==='gone-force') {
      owner.writePrivate(sidecar,{...owner.readPrivate(worker),location:{directory:wt},serviceStart:'0'});
      fs.renameSync(lab+'/native/service.json',lab+'/native/retained.json');
    }
   const verdict=await session.reconcileWorker('status',sidecar,wt);
    if(phase==='gone-force') assert.equal(verdict.incarnation,'unverifiable'); else assert.deepEqual(verdict,{executing:false,recorded:false});
    const exit=spawnSync(root+'/bin/fm-control.sh',[id,'exit'],{encoding:'utf8',env:failedEnv});
    const interrupt=spawnSync(root+'/bin/fm-control.sh',[id,'interrupt'],{encoding:'utf8',env:failedEnv});
    if(phase==='gone-force') {
      assert.notEqual(exit.status,0); assert.match(exit.stderr,/may resume/);
      assert.notEqual(interrupt.status,0); assert.doesNotMatch(interrupt.stdout,/cancel=confirmed/);
      const ordinary=spawnSync(root+'/bin/fm-teardown.sh',[id],{encoding:'utf8',env:failedEnv}); assert.notEqual(ordinary.status,0); assert.match(ordinary.stderr,/may resume/);
      assert.equal(fs.existsSync(wt),true); assert.equal(fs.existsSync(state+'/'+id+'.meta'),true);
    } else {
      assert.equal(exit.status,0,exit.stderr); assert.match(exit.stderr,/no recorded native session/);
      assert.equal(interrupt.status,0,interrupt.stderr); assert.match(interrupt.stdout,/cancel=not-needed/); assert.doesNotMatch(interrupt.stdout,/cancel=confirmed/);
    }
   const teardown=spawnSync(root+'/bin/fm-teardown.sh',[id,...(forced?['--force']:[])],{encoding:'utf8',env:failedEnv});
    assert.equal(teardown.status,0,teardown.stderr+'\n'+teardown.stdout);assert.equal(fs.existsSync(wt),false);assert.equal(fs.existsSync(state+'/'+id+'.meta'),false);
    if(phase==='gone-force') { assert.match(teardown.stderr,/forced discard without confirmed native cancellation/); fs.renameSync(lab+'/native/retained.json',lab+'/native/service.json'); }
 }
 // Absence is distinct from a present unsafe/malformed record, even after the
 // service is gone. No damaged proof is permitted to claim "not executing".
 const damaged=lab+'/damaged.json';fs.writeFileSync(damaged,'{',{mode:0o600});await assert.rejects(session.reconcileWorker('discard',damaged,root),SyntaxError);fs.unlinkSync(damaged);
 owner.writePrivate(damaged,{...owner.readPrivate(worker),servicePID:1});await assert.rejects(session.reconcileWorker('discard',damaged,root),/invalid recorded/);
 owner.writePrivate(damaged,{...owner.readPrivate(worker),serviceStart:'000'});await assert.rejects(session.reconcileWorker('discard',damaged,root),/invalid recorded/);
 owner.writePrivate(damaged,owner.readPrivate(worker));fs.chmodSync(damaged,0o644);await assert.rejects(session.reconcileWorker('teardown',damaged,root),/unsafe record/);fs.chmodSync(damaged,0o600);
  const absent=state+'/absent.opencode-v2-session.json';
  fs.symlinkSync(lab+'/does-not-exist',absent);await assert.rejects(session.reconcileWorker('discard',absent,root),/symlink/);fs.unlinkSync(absent);
  fs.writeFileSync(state+'/absent.busy-state','v1 gen=fixture seq=1 state=busy source=opencode-plugin event=started ts=1\n',{mode:0o600});
  await assert.rejects(session.reconcileWorker('teardown',absent,root),/busy record.*--force/);
  assert.equal((await session.reconcileWorker('discard',absent,root)).cancellation,'unconfirmed');fs.unlinkSync(state+'/absent.busy-state');
  // A dead original can leave execution in the successor at the frozen endpoint.
  process.env.FIXTURE_ROOT=root;
 const deadService=spawn(process.execPath,['-e','setInterval(()=>{},10000)'],{stdio:'ignore'});
 const birth=owner.identity(deadService.pid),deadRecord={...owner.readPrivate(worker),servicePID:birth.pid,serviceStart:birth.start,hostBootID:birth.boot};
 const closed=new Promise(resolve=>deadService.on('close',resolve));deadService.kill();await closed;
 owner.writePrivate(damaged,deadRecord);
 let proofLog=fs.readFileSync(process.env.FIXTURE_LOG,'utf8');
  fs.writeFileSync(process.env.FIXTURE_ACTIVE,'resumed');
  assert.equal((await session.reconcileWorker('status',damaged,root)).executing,true);
  await assert.rejects(session.reconcileWorker('teardown',damaged,root),/still executing/);
  assert.equal((await session.reconcileWorker('interrupt',damaged,root)).cancellation,'confirmed');
  assert.equal(fs.existsSync(process.env.FIXTURE_ACTIVE),false);
  assert.equal(owner.readPrivate(damaged).servicePID,me.pid,'confirmed successor cancellation did not update recorded service binding');
  assert.equal((await session.reconcileWorker('teardown',damaged,root)).executing,false);
  owner.writePrivate(damaged,deadRecord);
  assert.equal((await session.reconcileWorker('teardown',damaged,root)).cancellation,'confirmed'); // positive terminal acknowledgment settles old claim
  owner.writePrivate(damaged,deadRecord);
  process.env.FIXTURE_IDLE_INTERRUPT='1';
  assert.equal((await session.reconcileWorker('status',damaged,root)).cancellation,'unproven');
  assert.equal((await session.reconcileWorker('status',damaged,root)).executing,null);
  await assert.rejects(session.reconcileWorker('teardown',damaged,root),/no terminal cancellation/);
  await assert.rejects(session.reconcileWorker('interrupt',damaged,root),/no terminal cancellation/);
  assert.equal((await session.reconcileWorker('discard',damaged,root)).cancellation,'unconfirmed');
  delete process.env.FIXTURE_IDLE_INTERRUPT;
  owner.writePrivate(damaged,{...owner.readPrivate(worker),serviceStart:'0'});assert.equal((await session.reconcileWorker('discard',damaged,root)).cancellation,'confirmed');
  owner.writePrivate(damaged,{...owner.readPrivate(worker),hostBootID:'00000000-0000-0000-0000-000000000000'});assert.equal((await session.reconcileWorker('discard',damaged,root)).cancellation,'confirmed');
  proofLog=fs.readFileSync(process.env.FIXTURE_LOG,'utf8');
  owner.writePrivate(damaged,deadRecord);
  fs.renameSync(lab+'/native/service.json',lab+'/native/retained.json');
  for(const action of ['teardown','interrupt']) await assert.rejects(session.reconcileWorker(action,damaged,root),/may resume/);
  assert.equal((await session.reconcileWorker('discard',damaged,root)).cancellation,'unconfirmed');
  assert.equal(fs.readFileSync(process.env.FIXTURE_LOG,'utf8'),proofLog,'offline service must never start/query a default');
  fs.renameSync(lab+'/native/retained.json',lab+'/native/service.json');
 owner.writePrivate(damaged,owner.readPrivate(worker));
 fs.renameSync(lab+'/native/service.json',lab+'/native/retained.json');
 await assert.rejects(session.reconcileWorker('discard',damaged,root),/unregistered/); // matching original process still lives
 fs.renameSync(lab+'/native/retained.json',lab+'/native/service.json');
 assert.equal(fs.readFileSync(process.env.FIXTURE_LOG,'utf8'),proofLog,'live unverifiable service must refuse without cancellation');
 const replacement=spawn(process.execPath,['-e','setInterval(()=>{},10000)'],{stdio:'ignore'}),replacementClosed=new Promise(resolve=>replacement.on('close',resolve));
 const originalRegistration=owner.readPrivate(lab+'/native/service.json');
 try {
   owner.writePrivate(lab+'/native/service.json',{...originalRegistration,pid:replacement.pid});
   await assert.rejects(session.reconcileWorker('discard',damaged,root),/different service incarnation/);
   assert.equal(fs.readFileSync(process.env.FIXTURE_LOG,'utf8'),proofLog,'registration replacement must not prove the still-live original service stopped');
 } finally {owner.writePrivate(lab+'/native/service.json',originalRegistration);replacement.kill();await replacementClosed;}
  const log=fs.readFileSync(process.env.FIXTURE_LOG,'utf8');assert.match(log,/shell.list/);assert.equal(log.split('session.interrupt').length-1,10);
  const sample={record:owner.readPrivate(worker),binding:owner.readPrivate(worker),args:[],executing:false};
  let age=31000,latest={type:'assistant',finish:'stop',time:{completed:Date.now()-500}},active={},waited=0;
  const deps={timing:()=>({age,started:Date.now()-age}),wait:async ms=>{assert.equal(ms,1000);waited++;},api:(_record,op,args)=>{
    if(op==='session.active') return {data:active};
    assert.equal(op,'session.message.list'); assert.ok(args.includes('order=desc')); assert.ok(args.includes('limit=1')); return {data:[latest]};
  }};
  assert.equal(await session.settledSuccessor(sample,deps),true);assert.equal(waited,1);
  for(const outcome of ['succeeded','failed','interrupted']) {
    latest={type:'idle',outcome,time:{created:Date.now()-60000}};assert.equal(await session.settledSuccessor(sample,deps),true);
  }
  latest={type:'assistant',finish:'stop',time:{completed:Date.now()-60000}};assert.equal(await session.settledSuccessor(sample,deps),true);
  age=29999;const beforeWait=waited;assert.equal(await session.settledSuccessor(sample,deps),false);assert.equal(waited,beforeWait);age=31000;
  active={[r.sessionID]:{type:'running'}};assert.equal(await session.settledSuccessor(sample,deps),false);active={};
  assert.equal(await session.settledSuccessor({...sample,executing:true},deps),false);
  for(const message of [{type:'synthetic',text:'Continuing after restart',time:{created:Date.now()-500}},{type:'user',time:{completed:Date.now()-500}},{type:'assistant',finish:'tool-calls',time:{completed:Date.now()-500}},{type:'assistant',finish:'stop',time:{}},{type:'idle',outcome:'shutdown',time:{created:Date.now()-60000}}]) {
    latest=message;assert.equal(await session.settledSuccessor(sample,deps),false);
  }
 console.log('frozen registered endpoint, cwd/session divergence and exact worker execution/cancellation passed');
} finally {child.kill();await new Promise(resolve=>child.on('close',resolve));owner.publish('cleanup-test-namespace',{});}
JS
  ) || fail "endpoint/execution behavior: $out"
  pass "$out"
}
test_frozen_endpoint_and_worker_execution

out=$(env ROOT="$ROOT" LAB="$TMP_ROOT/provider-host" node "$ROOT/tests/fixtures/fm-opencode-v2-provider-host.mjs" 2>&1) || fail "native provider/lifecycle regression: $out"
pass "$out"
for notice in transient persistent; do
  out=$(env ROOT="$ROOT" LAB="$TMP_ROOT/notice-$notice" node "$ROOT/tests/fixtures/fm-opencode-v2-provider-host.mjs" "--notice-$notice" 2>&1) || fail "$notice failure notice regression: $out"
  pass "$out"
done
for review in prepare prepare-empty prepare-generation rejected timeout wrong-id invalid reload-pending prune; do
  out=$(env ROOT="$ROOT" LAB="$TMP_ROOT/review-$review" node "$ROOT/tests/fixtures/fm-opencode-v2-provider-host.mjs" "--review-$review" 2>&1) || fail "$review PR review regression: $out"
  pass "$out"
done

out=$(env ROOT="$ROOT" LAB="$TMP_ROOT/real-recovery" node "$ROOT/tests/fixtures/fm-opencode-v2-real-recovery.mjs" 2>&1) || fail "real native recovery regression: $out"
pass "$out"
