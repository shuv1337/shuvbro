// Manual CLI driver: runs bin/fm-native.mjs as a subprocess against a private fake Herdr
// socket (JSON-lines protocol) and a fake Shuvcode supervisor CLI. Never touches host Herdr/Shuvcode.
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
const exe = process.argv[2];
const dir = await mkdtemp(join(tmpdir(), "fm-native-drive-"));
const home = join(dir, "native"), sock = join(dir, "herdr.sock"), project = join(dir, "project"), fake = join(dir, "shuvcode.mjs");
await mkdir(project);
await writeFile(fake, `import { readFile, writeFile, appendFile } from 'node:fs/promises';import { join } from 'node:path';
const base=process.argv[2], args=process.argv.slice(3);await appendFile(join(base,'native-calls.jsonl'),JSON.stringify(args)+'\\n');
const home=args[args.indexOf('--home')+1];
if(args[1]==='init'){const p=JSON.parse(await readFile(args[args.indexOf('--profile')+1],'utf8'));if(p.version!==1||p.id!=='shuvbro')process.exit(2);await writeFile(join(home,'settings.json'),JSON.stringify({pilotID:'native-home-id'}));}
if(args[1]==='presentation')process.stdout.write(await readFile(join(base,'projection.json'),'utf8'));
if(args[1]==='task')process.stdout.write('typed task result '+JSON.stringify(args)+'\\n');`);
const facts = [["lead","Lead"],["ship","Ship A"],["ship","Ship B"]].map(([role,title],i)=>({id:`entry-${i}`,role,taskID:i?`task-${i}`:undefined,title,sessionID:`ses_${i}`,location:project,state:i?"working":"idle",available:true,settled:false,retired:false,attachment:{provider:"shuvcode",home_id:"native-home-id",session_id:`ses_${i}`,location:project,host_id:"local",attach_argv:["/private/shuvcode","supervisor","attach","--home",home,"--home-id","native-home-id","--session",`ses_${i}`,"--location",project]}}));
const projection = { version: 1, homeID: "native-home-id", home, entries: facts };
const publish = () => writeFile(join(dir,"projection.json"), JSON.stringify(projection));
await publish();
const S = { panes: new Map([["@neighbor:1:1",{pane_id:"@neighbor:1:1",workspace_id:"@neighbor",tab_id:"@neighbor:1"}]]), bindings: new Map(), procs: new Map(), creates: 0, launches: 0, caps: true, lose: undefined, log: [] };
const server = createServer(c => { let input=""; c.on("data", d => { input += d; if (!input.includes("\n")) return;
  const r = JSON.parse(input.split("\n")[0]), p = r.params; S.log.push(r.method + (p.focus!==undefined?` focus=${p.focus}`:"") + (p.source_workspace_id?` source=${p.source_workspace_id}`:"") + (p.label?` label=${JSON.stringify(p.label)}`:"") + (p.state?` state=${p.state} seq=${p.seq} ttl=${p.ttl_ms}`:""));
  let res = {type:"ok"}, err;
  if (r.method==="ping") res = {capabilities:{runtime_attachment_methods: S.caps ? ["pane.bind_runtime","pane.get_runtime","pane.report_runtime","pane.unbind_runtime"] : []}};
  else if (r.method==="workspace.get") { if (!["@parent","@neighbor"].includes(p.workspace_id) && !p.workspace_id.startsWith("@native")) err={code:"workspace_not_found",message:"x"}; else res={workspace:{workspace_id:p.workspace_id}}; }
  else if (r.method==="workspace.create") { const id=`@native-${++S.creates}`, pane={pane_id:`${id}:1:1`,workspace_id:id,tab_id:`${id}:1`}; S.panes.set(pane.pane_id,pane); res={workspace:{workspace_id:id},tab:{tab_id:pane.tab_id},root_pane:pane}; }
  else if (r.method==="pane.get") { const pane=S.panes.get(p.pane_id); if(!pane) err={code:"pane_not_found",message:"x"}; else res={pane}; }
  else if (r.method==="pane.get_runtime") res={binding:S.bindings.get(p.pane_id)??null};
  else if (r.method==="pane.bind_runtime") { const ex=S.bindings.get(p.pane_id); if(ex&&ex.binding_id!==p.binding_id) err={code:"runtime_conflict",message:"foreign"}; else { const b=ex??{...p,seq:null,state:"unknown"}; S.bindings.set(p.pane_id,b); res={applied:true,binding:b}; } }
  else if (r.method==="pane.report_runtime") { const b=S.bindings.get(p.pane_id); const ok=b?.binding_id===p.binding_id&&p.seq>(b.seq??0); if(ok){b.seq=p.seq;b.state=p.state;} res={applied:ok,binding:b}; }
  else if (r.method==="pane.process_info") res={process_info:S.procs.get(p.pane_id)??{shell_pid:100,foreground_process_group_id:100,foreground_processes:[{pid:100,argv:["/bin/sh"]}]}};
  else if (r.method==="pane.send_input") { S.launches++; S.procs.set(p.pane_id,{shell_pid:100,foreground_process_group_id:101,foreground_processes:[{pid:101,argv:S.bindings.get(p.pane_id).attachment.attach_argv}]}); }
  else if (r.method==="pane.close") { S.panes.delete(p.pane_id); S.bindings.delete(p.pane_id); }
  else err={code:"unknown_method",message:r.method};
  if (S.lose===r.method) { S.lose=undefined; c.end(); return; }
  c.end(JSON.stringify(err?{id:r.id,error:err}:{id:r.id,result:res})+"\n"); }); });
await new Promise(ok => server.listen(sock, ok));
const run = (...a) => new Promise(ok => { const ch = spawn(process.execPath, [exe, ...a], { env: { PATH: process.env.PATH, HOME: dir } }); let o="",e=""; ch.stdout.on("data",d=>o+=d); ch.stderr.on("data",d=>e+=d); ch.on("close",code=>ok({code,o,e})); });
const sh = s => s.replaceAll(dir, "$TMP");
async function step(title, ...a) { S.log=[]; const r = await run(...a); console.log(`\n### ${title}\n$ fm-native.mjs ${sh(a.join(" "))}\nexit=${r.code}`); if (r.o.trim()) console.log("stdout: " + sh(r.o.trim()).slice(0, 1500)); if (r.e.trim()) console.log("stderr: " + sh(r.e.trim())); if (S.log.length) console.log("herdr calls: " + S.log.join(" | ")); return r; }
const journal = async () => JSON.parse(await readFile(join(home,"native-display.json"),"utf8"));
const phases = async () => Object.fromEntries(Object.values((await journal()).entries).map(e=>[e.id,`${e.phase} pane=${e.paneID} seq=${e.seq} binding=${e.bindingID.slice(-8)}`]));
const nativeCalls = async () => (await readFile(join(dir,"native-calls.jsonl"),"utf8")).trim().split("\n").map(l=>JSON.parse(l)[1]);
const init = (...x) => ["init","--home",home,"--project",project,"--herdr-socket",sock,"--herdr-session","native-drive","--parent-workspace","@parent","--shuvcode-command",JSON.stringify([process.execPath,fake,dir]),...x];
const sc = process.argv[3];
const out = (k,v) => console.log(`${k}: ${typeof v==="string"?v:JSON.stringify(v)}`);
if (sc === "guards") {
  await step("default Herdr session refused", "init","--home",home,"--project",project,"--herdr-socket",sock,"--herdr-session","default","--parent-workspace","@parent","--shuvcode-command",JSON.stringify([process.execPath,fake,dir]));
  await step("credential in attach argv refused", "init","--home",home,"--project",project,"--herdr-socket",sock,"--herdr-session","native-drive","--parent-workspace","@parent","--shuvcode-command",JSON.stringify([process.execPath,"--token=abc"]));
  S.caps = false; await step("old Herdr without runtime methods refused before native init", ...init());
  out("native CLI calls so far", await nativeCalls().catch(()=>[])); out("creates", S.creates);
  S.caps = true; await step("re-init over an existing home refused (no takeover)", ...init());
  await mkdir(join(dir,"legacy")); await writeFile(join(dir,"legacy","state.json"),"{}");
  await step("existing legacy home refused", "init","--home",join(dir,"legacy"),"--project",project,"--herdr-socket",sock,"--herdr-session","native-drive","--parent-workspace","@parent","--shuvcode-command",JSON.stringify([process.execPath,fake,dir]));
  await step("sync on a non-native legacy home refused", "sync","--home",join(dir,"legacy"));
  out("legacy home contents unchanged", await readFile(join(dir,"legacy","state.json"),"utf8"));
}
if (sc === "main") {
  await step("help", "--help");
  await step("init new native home (lead role)", ...init("--model","test/m"));
  out("native calls", await nativeCalls());
  await step("up: start supervisor + reconcile lead and two workers", "up","--home",home);
  out("journal phases", await phases()); out("creates/launches", [S.creates,S.launches]); out("neighbor pane untouched", S.panes.has("@neighbor:1:1"));
  await step("control: typed native task op is passed through", "control","--home",home,"--","task","steer","--id","task-1","--message","hi");
  await step("control: attach refused (attach-only has dedicated path)", "control","--home",home,"--","attach");
  await step("sync again: idempotent, increasing seq, no duplicates", "sync","--home",home);
  out("journal phases", await phases()); out("creates/launches", [S.creates,S.launches]);
  // authority conflict
  const j = await journal(); const p1 = j.entries["entry-1"].paneID;
  const saved = S.bindings.get(p1).binding_id; S.bindings.get(p1).binding_id = "someone-else";
  await step("authority conflict: foreign binding on worker pane", "sync","--home",home);
  facts[1].settled = true; await publish();
  await step("cleanup refused under foreign binding even when settled", "cleanup","--home",home,"--entry","entry-1");
  out("pane still present", S.panes.has(p1)); S.bindings.get(p1).binding_id = saved; facts[1].settled = false; await publish();
  // cleanup
  facts[1].state = "done"; await publish();
  await step("cleanup refused: state=done but not settled", "cleanup","--home",home,"--entry","entry-1");
  facts[1].settled = true; facts[1].retired = true; await publish();
  S.lose = "pane.close";
  await step("cleanup with lost pane.close reply", "cleanup","--home",home,"--entry","entry-1");
  out("entry-1", (await phases())["entry-1"]);
  await step("cleanup retried: exact readback confirms close", "cleanup","--home",home,"--entry","entry-1");
  out("remaining panes", [...S.panes.keys()]);
  // display close while execution continues
  const p2 = (await journal()).entries["entry-2"].paneID; S.panes.delete(p2); S.bindings.delete(p2);
  const before = (await nativeCalls()).length;
  await step("user closes worker B view while it keeps working", "sync","--home",home);
  out("entry-2", (await phases())["entry-2"]); out("native calls during sync", (await nativeCalls()).slice(before)); out("creates (no recreation)", S.creates);
  await step("explicit reopen of closed worker B view", "reopen","--home",home,"--entry","entry-2");
  out("entry-2", (await phases())["entry-2"]); out("creates/launches", [S.creates,S.launches]);
  await step("reopen of retired worker A refused", "reopen","--home",home,"--entry","entry-1");
  out("all native CLI subcommands invoked", [...new Set(await nativeCalls())]);
}
if (sc === "lost") {
  await step("init", ...init());
  S.lose = "workspace.create";
  await step("sync with lost workspace.create reply for lead", "sync","--home",home);
  out("journal phases", await phases()); out("creates", S.creates);
  await step("sync again: uncertain creation stays pending, others reported", "sync","--home",home);
  out("journal phases", await phases()); out("creates (no duplicate)", S.creates);
  const g = await journal(); 
  const d2 = join(dir, "n2");
  S.lose = undefined;
}
if (sc === "restart") {
  await step("init", ...init());
  const watch = () => spawn(process.execPath, [exe, "watch", "--home", home], { env: { PATH: process.env.PATH, HOME: dir }, stdio: "ignore" });
  let w = watch(); await new Promise(r => setTimeout(r, 3000));
  out("after watch #1 3s", await phases()); out("creates/launches", [S.creates,S.launches]);
  w.kill("SIGINT"); await new Promise(r => w.on("close", r));
  const ttl = [...S.bindings.values()].map(b=>b.state);
  out("adapter stopped; binding states (expire to unknown via ttl_ms=5000 in Herdr)", ttl);
  facts[1].state = "blocked"; await publish();
  w = watch(); await new Promise(r => setTimeout(r, 3000));
  out("after independent restart watch #2", await phases()); out("creates/launches (unchanged=3/3)", [S.creates,S.launches]);
  out("worker A binding state now", S.bindings.get((await journal()).entries["entry-1"].paneID).state);
  await step("status while watch runs (lock only per pass)", "status","--home",home);
  w.kill(); await new Promise(r => w.on("close", r));
}
server.close(); await rm(dir, { recursive: true, force: true });
