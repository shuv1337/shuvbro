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
  await writeFile(fake, `import { readFile, writeFile, appendFile } from 'node:fs/promises';\nimport { join } from 'node:path';\nconst base=process.argv[2], args=process.argv.slice(3);\nawait appendFile(join(base,'native-calls.jsonl'),JSON.stringify(args)+'\\n');\nconst home=args[args.indexOf('--home')+1];\nif(args[1]==='init'){const profile=JSON.parse(await readFile(args[args.indexOf('--profile')+1],'utf8'));if(profile.id!=='shuvbro'||!profile.leadInstructions.includes('native supervisor'))process.exit(2);await writeFile(join(home,'settings.json'),JSON.stringify({pilotID:'native-home-id'}));}\nif(args[1]==='presentation')process.stdout.write(await readFile(join(base,'projection.json'),'utf8'));\n`);
  await writeFile(fake, await readFile(fake, "utf8") + "if(args[1]==='status')process.stdout.write('typed native output\\n');\n");
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
  async function init(extra = []) { return run("init", "--home", home, "--project", project, "--herdr-socket", socket, "--herdr-session", "native-test", "--parent-workspace", "@parent", "--shuvcode-command", JSON.stringify([process.execPath, fake, directory]), ...extra); }
  async function journal() { return JSON.parse(await readFile(join(home, "native-display.json"), "utf8")); }
  async function nativeCalls() { return (await readFile(join(directory, "native-calls.jsonl"), "utf8")).trim().split("\n").map(line => JSON.parse(line)); }
  return { directory, home, projection, facts, state, publish, run, init, journal, nativeCalls };
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

test("lost create result remains uncertain and never allocates a duplicate", async t => {
  const f = await fixture(t); strictEqual((await f.init()).code, 0);
  f.state.lose = "workspace.create";
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual((await f.run("sync", "--home", f.home)).code, 1);
  strictEqual(f.state.creates, 1); strictEqual(f.state.launches, 0);
  strictEqual((await f.journal()).entries["entry-0"].phase, "create_pending");
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
