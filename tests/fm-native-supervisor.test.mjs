import { test } from "node:test";
import { strictEqual, deepStrictEqual, ok, match } from "node:assert";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const executable = fileURLToPath(new URL("../bin/fm-native.mjs", import.meta.url));

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "fm-native-test-"));
  const home = join(directory, "native"), socket = join(directory, "herdr.sock"), project = join(directory, "project"), fake = join(directory, "shuvcode.mjs");
  await mkdir(project);
  await writeFile(fake, `import { readFile, writeFile, appendFile } from 'node:fs/promises';\nimport { join } from 'node:path';\nconst base=process.argv[2], args=process.argv.slice(3);\nawait appendFile(join(base,'native-calls.jsonl'),JSON.stringify(args)+'\\n');\nconst home=args[args.indexOf('--home')+1];\nif(args[1]==='init'){const profile=JSON.parse(await readFile(args[args.indexOf('--profile')+1],'utf8'));if(profile.version!==1||profile.id!=='shuvbro'||typeof profile.leadInstructions!=='string'||!profile.leadInstructions.trim())process.exit(2);await writeFile(join(home,'settings.json'),JSON.stringify({pilotID:'native-home-id'}));}\nif(args[1]==='presentation')process.stdout.write(await readFile(join(base,'projection.json'),'utf8'));\n`);
  await writeFile(fake, await readFile(fake, "utf8") + "if(args[1]==='status')process.stdout.write('typed native output\\n');\n");
  await writeFile(fake, await readFile(fake, "utf8") + "if(args[1]==='presentation'){const marker=join(base,'presentation-inflight');try{await writeFile(marker,'',{flag:'wx'});}catch{await appendFile(join(base,'overlaps'),'x');}await new Promise(r=>setTimeout(r,30));await import('node:fs/promises').then(fs=>fs.rm(marker,{force:true}));}\n");
  const facts = ["lead", "ship", "scout"].map((role, index) => ({ id: `entry-${index}`, role, taskID: index ? `task-${index}` : undefined, title: `View ${index}`, sessionID: `ses_${index}`, location: project, state: index === 2 ? "blocked" : index === 1 ? "working" : "idle", available: true, settled: false, retired: false, attachment: { provider: "shuvcode", home_id: "native-home-id", session_id: `ses_${index}`, location: project, host_id: "local", attach_argv: ["/private/shuvcode", "supervisor", "attach", "--home", home, "--home-id", "native-home-id", "--session", `ses_${index}`, "--location", project] } }));
  const projection = { version: 1, homeID: "native-home-id", home, entries: facts, observedAt: 0, endpoint: "http://127.0.0.1:1" };
  const state = { calls: [], panes: new Map(), bindings: new Map(), processes: new Map(), workspaces: new Set(["@parent", "@neighbor"]), creates: 0, launches: 0, focus: "@neighbor", capabilities: true, lose: undefined };
  state.panes.set("@neighbor:1:1", { pane_id: "@neighbor:1:1", workspace_id: "@neighbor", tab_id: "@neighbor:1" });
  const server = createServer(connection => {
    let input = "";
    connection.on("data", data => {
      input += data;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.split("\n")[0]);
      state.calls.push(request);
      const known = ["ping", "workspace.get", "workspace.create", "pane.get", "pane.get_runtime", "pane.bind_runtime", "pane.report_runtime", "pane.send_input", "pane.process_info", "pane.close"];
      if (!known.includes(request.method)) { connection.end(JSON.stringify({id: request.id, error: {code: "unknown_method", message: request.method}}) + "\n"); return; }
      let result = { type: "ok" }, error;
      const params = request.params;
      if (request.method === "ping") result = { type: "pong", capabilities: { runtime_attachment_methods: state.capabilities ? ["pane.bind_runtime", "pane.get_runtime", "pane.report_runtime", "pane.unbind_runtime"] : [] } };
      if (request.method === "workspace.get") { if (!state.workspaces.has(params.workspace_id)) error = { code: "workspace_not_found", message: "missing" }; else result = { workspace: { workspace_id: params.workspace_id } }; }
      if (request.method === "workspace.create") {
        strictEqual(params.focus, false);
        strictEqual(params.source_workspace_id, "@parent");
        const id = `@native-${++state.creates}`, pane = { pane_id: `${id}:1:1`, workspace_id: id, tab_id: `${id}:1` };
        state.panes.set(pane.pane_id, pane); state.workspaces.add(id);
        result = { type: "workspace_created", workspace: { workspace_id: id }, tab: { tab_id: pane.tab_id }, root_pane: pane };
      }
      if (request.method === "pane.get") { const pane = state.panes.get(params.pane_id); if (!pane) error = { code: "pane_not_found", message: "missing" }; else result = { type: "pane_info", pane }; }
      if (request.method === "pane.get_runtime") result = { type: "pane_runtime", binding: state.bindings.get(params.pane_id) ?? null };
      if (request.method === "pane.bind_runtime") {
        const existing = state.bindings.get(params.pane_id);
        if (existing && existing.binding_id !== params.binding_id) error = { code: "runtime_conflict", message: "foreign" };
        else { const binding = existing ?? { ...params, seq: null, state: "unknown", fresh: false }; state.bindings.set(params.pane_id, binding); result = { type: "pane_runtime", applied: true, binding }; }
      }
      if (request.method === "pane.report_runtime") {
        const binding = state.bindings.get(params.pane_id);
        const applied = binding?.binding_id === params.binding_id && params.seq > (binding.seq ?? 0);
        if (applied) { binding.seq = params.seq; binding.state = params.state; binding.fresh = true; }
        result = { type: "pane_runtime", applied, binding };
      }
      if (request.method === "pane.process_info") result = { process_info: state.processes.get(params.pane_id) ?? { shell_pid: 100, foreground_process_group_id: 100, foreground_processes: [{ pid: 100, argv: ["/bin/sh"] }] } };
      if (request.method === "pane.send_input") { state.launches++; match(params.text, /'supervisor' 'attach'/); deepStrictEqual(params.keys, ["Enter"]); state.processes.set(params.pane_id, { shell_pid: 100, foreground_process_group_id: 101, foreground_processes: [{ pid: 101, argv: state.bindings.get(params.pane_id).attachment.attach_argv }] }); }
      if (request.method === "pane.close") { state.panes.delete(params.pane_id); state.bindings.delete(params.pane_id); }
      if (state.lose === request.method) { state.lose = undefined; connection.end(); return; }
      connection.end(JSON.stringify(error ? { id: request.id, error } : { id: request.id, result }) + "\n");
    });
  });
  await new Promise(resolve => server.listen(socket, resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  async function publish() { await writeFile(join(directory, "projection.json"), JSON.stringify(projection)); }
  await publish();
  async function run(...args) {
    return new Promise(resolveResult => {
      const child = spawn(process.execPath, [executable, ...args], { env: { PATH: process.env.PATH, HOME: directory }, stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "", stderr = "";
      child.stdout.on("data", data => stdout += data); child.stderr.on("data", data => stderr += data);
      child.on("close", code => resolveResult({ code, stdout, stderr }));
    });
  }
  function start(...args) {
    const child = spawn(process.execPath, [executable, ...args], { env: { PATH: process.env.PATH, HOME: directory }, stdio: ["ignore", "ignore", "ignore"] });
    const closed = new Promise(resolve => child.on("close", resolve));
    t.after(() => { child.kill(); return closed; });
    return { child, closed };
  }
  async function until(predicate) {
    for (const deadline = Date.now() + 15000; Date.now() < deadline; await new Promise(resolve => setTimeout(resolve, 50))) {
      try { const value = await predicate(); if (value) return value; } catch {}
    }
    throw new Error("Timed out waiting for native display state");
  }
  async function init(extra = []) { return run("init", "--home", home, "--project", project, "--herdr-socket", socket, "--herdr-session", "native-test", "--parent-workspace", "@parent", "--shuvcode-command", JSON.stringify([process.execPath, fake, directory]), ...extra); }
  async function journal() { return JSON.parse(await readFile(join(home, "native-display.json"), "utf8")); }
  async function nativeCalls() { return (await readFile(join(directory, "native-calls.jsonl"), "utf8")).trim().split("\n").map(line => JSON.parse(line)); }
  async function overlaps() { try { return (await readFile(join(directory, "overlaps"), "utf8")).length; } catch (error) { if (error.code === "ENOENT") return 0; throw error; } }
  return { directory, home, projection, facts, state, publish, run, start, until, init, journal, nativeCalls, overlaps };
}

test("native init/profile and explicit up converge on exact no-focus views; cleanup needs settlement", async t => {
  const f = await fixture(t);
  strictEqual((await f.init(["--model", "test/test-model", "--provider-url", "http://127.0.0.1:123/v1", "--auto"])).code, 0);
  const nativeInit = (await f.nativeCalls())[0];
  ok(nativeInit.includes("--profile")); ok(nativeInit.includes("test/test-model")); ok(nativeInit.includes("--provider-url")); ok(nativeInit.includes("--auto"));
  strictEqual((await f.run("up", "--home", f.home)).code, 0);
  const status = await f.run("control", "--home", f.home, "--", "status", "--json");
  strictEqual(status.code, 0); strictEqual(status.stdout, "typed native output\n");
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3); strictEqual(f.state.focus, "@neighbor");
  const first = await f.journal();
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  const second = await f.journal();
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3);
  strictEqual(first.entries["entry-1"].bindingID, second.entries["entry-1"].bindingID);
  strictEqual(second.entries["entry-1"].seq, 2);
  strictEqual((await f.run("cleanup", "--home", f.home, "--entry", "entry-1")).code, 1);
  f.facts[1].state = "done"; await f.publish();
  strictEqual((await f.run("cleanup", "--home", f.home, "--entry", "entry-1")).code, 1); // done alone is insufficient
  f.facts[1].settled = true; f.facts[1].retired = true; await f.publish();
  f.state.lose = "pane.close";
  strictEqual((await f.run("cleanup", "--home", f.home, "--entry", "entry-1")).code, 1);
  strictEqual((await f.run("cleanup", "--home", f.home, "--entry", "entry-1")).code, 0);
  ok(f.state.panes.has("@neighbor:1:1")); strictEqual(f.state.panes.size, 3);
  strictEqual((await f.run("sync", "--home", f.home)).code, 0); strictEqual(f.state.creates, 3);
  ok(!f.state.calls.some(call => call.method === "workspace.close"));
  ok((await f.nativeCalls()).every(call => ["init", "up", "presentation", "status"].includes(call[1])));
});

test("lost binding/report replies reconcile retained identity and increasing sequence", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  f.state.lose = "pane.bind_runtime";
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual((await f.journal()).entries["entry-0"].phase, "bind_pending");
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3);
  f.state.lose = "pane.report_runtime";
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3);
  const entry = (await f.journal()).entries["entry-0"];
  strictEqual(f.state.bindings.get(entry.paneID).seq, entry.seq); strictEqual(entry.seq, 3);
});

test("lost create result remains uncertain without blocking or duplicating other views", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  f.state.lose = "workspace.create";
  const failed = await f.run("sync", "--home", f.home);
  strictEqual(failed.code, 1); match(failed.stderr, /entry-0: Uncertain|entry-0: Herdr workspace.create/);
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 2);
  const first = await f.journal();
  strictEqual(first.entries["entry-0"].phase, "create_pending");
  strictEqual(first.entries["entry-1"].phase, "ready"); strictEqual(first.entries["entry-2"].phase, "ready");
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 2);
  const second = await f.journal();
  strictEqual(second.entries["entry-0"].phase, "create_pending");
  for (const id of ["entry-1", "entry-2"]) {
    strictEqual(second.entries[id].seq, first.entries[id].seq + 1);
    strictEqual(f.state.bindings.get(second.entries[id].paneID).seq, second.entries[id].seq);
  }
});

test("a worker without a title is refused before any pending creation is journaled", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  delete f.facts[1].title; await f.publish();
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual(f.state.creates, 0); deepStrictEqual((await f.journal()).entries, {});
  f.facts[1].title = "View 1"; await f.publish();
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual(f.state.creates, 3);
  ok(Object.values((await f.journal()).entries).every(entry => entry.phase === "ready"));
});

test("an entry gone from the projection whose pane disappears becomes closed", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0); strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  f.projection.entries.splice(1, 1); await f.publish();
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  const gone = (await f.journal()).entries["entry-1"];
  strictEqual(gone.phase, "ready"); strictEqual(f.state.bindings.get(gone.paneID).state, "unknown");
  f.state.panes.delete(gone.paneID); f.state.bindings.delete(gone.paneID);
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual((await f.journal()).entries["entry-1"].phase, "closed");
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual((await f.run("cleanup", "--home", f.home, "--entry", "entry-1")).code, 0);
  strictEqual(f.state.creates, 3);
});

test("explicit cleanup proceeds while watch runs and watch keeps the cleanup result", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  const watch = f.start("watch", "--home", f.home);
  const before = await f.until(async () => { const journal = await f.journal(); return Object.values(journal.entries).length === 3 && Object.values(journal.entries).every(entry => entry.phase === "ready") && journal; });
  f.facts[1].settled = true; f.facts[1].retired = true; await f.publish();
  const cleanup = await f.run("cleanup", "--home", f.home, "--entry", "entry-1");
  strictEqual(cleanup.code, 0, cleanup.stderr);
  ok(!f.state.panes.has(before.entries["entry-1"].paneID));
  const seq = (await f.journal()).entries["entry-0"].seq;
  const after = await f.until(async () => { const journal = await f.journal(); return journal.entries["entry-0"].seq >= seq + 2 && journal; });
  strictEqual(after.entries["entry-1"].phase, "closed");
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3);
  strictEqual(watch.child.exitCode, null);
  watch.child.kill(); await watch.closed;
});

test("concurrent passes hand off the home lock without overlapping", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  const results = await Promise.all(Array.from({ length: 8 }, () => f.run("sync", "--home", f.home)));
  deepStrictEqual(results.map(result => result.code), Array(8).fill(0), results.map(result => result.stderr).join(""));
  strictEqual(await f.overlaps(), 0);
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3);
  await rm(join(f.home, ".native-display-lock"), { force: false }).then(() => ok(false, "lock was not released"), error => strictEqual(error.code, "ENOENT"));
});

test("a stale lock from a stopped adapter is reclaimed by exactly one concurrent pass at a time", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  const dead = await new Promise(resolve => { const child = spawn(process.execPath, ["-e", ""]); child.on("close", () => resolve(child.pid)); });
  await writeFile(join(f.home, ".native-display-lock"), `${dead} ${"0".repeat(8)}-0000-0000-0000-${"0".repeat(12)}\n`);
  const results = await Promise.all(Array.from({ length: 8 }, () => f.run("sync", "--home", f.home)));
  deepStrictEqual(results.map(result => result.code), Array(8).fill(0), results.map(result => result.stderr).join(""));
  strictEqual(await f.overlaps(), 0);
  strictEqual(f.state.creates, 3); strictEqual(f.state.launches, 3);
});

test("an ambiguous lock is retained rather than taken over", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  await writeFile(join(f.home, ".native-display-lock"), "garbage\n");
  const result = await f.run("sync", "--home", f.home);
  strictEqual(result.code, 1); match(result.stderr, /Ambiguous native display lock/);
  strictEqual(await readFile(join(f.home, ".native-display-lock"), "utf8"), "garbage\n");
  strictEqual(f.state.creates, 0);
});

test("lost launch and Herdr restore of bound view never submit attach input twice", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  f.state.lose = "pane.send_input";
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual((await f.journal()).entries["entry-0"].phase, "launch_pending");
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual(f.state.launches, 3);
  const journal = await f.journal();
  journal.entries["entry-0"].phase = "bound";
  await writeFile(join(f.home, "native-display.json"), JSON.stringify(journal));
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual(f.state.launches, 3);
  journal.entries["entry-0"].phase = "bound";
  f.state.processes.set(journal.entries["entry-0"].paneID, { shell_pid: 100, foreground_process_group_id: 101, foreground_processes: [{ pid: 101, argv: ["/private/shuvcode", "other-session"] }] });
  await writeFile(join(f.home, "native-display.json"), JSON.stringify(journal));
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual(f.state.launches, 3);
});

test("display close and explicit reopen never control native execution", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0); strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  const old = (await f.journal()).entries["entry-1"];
  f.state.panes.delete(old.paneID); f.state.bindings.delete(old.paneID);
  strictEqual((await f.run("sync", "--home", f.home)).code, 0);
  strictEqual((await f.journal()).entries["entry-1"].phase, "closed"); strictEqual(f.state.creates, 3);
  strictEqual((await f.run("reopen", "--home", f.home, "--entry", "entry-1")).code, 0);
  const fresh = (await f.journal()).entries["entry-1"];
  ok(fresh.bindingID !== old.bindingID); ok(fresh.paneID !== old.paneID); strictEqual(f.state.creates, 4);
  ok((await f.nativeCalls()).every(call => ["init", "presentation"].includes(call[1])));
});

test("old Herdr, legacy homes, changed bindings and retired unavailable entries fail closed", async t => {
  const f = await fixture(t); f.state.capabilities = false;
  strictEqual((await f.init()).code, 1); strictEqual(f.state.creates, 0);
  strictEqual((await f.init()).code, 1); // existing home is not taken over
  const g = await fixture(t); strictEqual((await g.init()).code, 0);
  g.facts[1].retired = true; g.facts[2].available = false; await g.publish();
  strictEqual((await g.run("sync", "--home", g.home)).code, 0); strictEqual(g.state.creates, 1);
  const entry = (await g.journal()).entries["entry-0"];
  g.state.bindings.get(entry.paneID).binding_id = "foreign";
  strictEqual((await g.run("sync", "--home", g.home)).code, 1); strictEqual(g.state.creates, 1);
  g.facts[0].settled = true; await g.publish();
  strictEqual((await g.run("cleanup", "--home", g.home, "--entry", "entry-0")).code, 1);
  strictEqual(g.state.panes.size, 2); // foreign binding and neighbor retained
});
