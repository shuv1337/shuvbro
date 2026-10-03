// Faithful host seam: setup has no provider; app slot rendering does. Resources
// are real child processes; service APIs are local exact-session stand-ins.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
const source = process.env.ROOT, lab = process.env.LAB;
const owner = await import(pathToFileURL(source + "/bin/fm-opencode-v2-owner.mjs"));
const tui = (await import(pathToFileURL(source + "/.opencode/plugins/fm-native-v2/tui.js"))).default;
const { createWatchArmCoordinator } = await import(pathToFileURL(source + "/.opencode/plugins/lib/fm-watch-arm-v2.js"));
const { createAdmissionJournal } = await import(pathToFileURL(source + "/.opencode/plugins/fm-native-v2/admission.js"));
const root = lab + "/root", home = lab + "/home", state = home + "/state";
async function until(test, message) {
  for (let i = 0; i < 100; i++) { if (await test()) return; await delay(50); }
  throw new Error(message);
}
function running(pid) {
  try { owner.identity(Number(pid)); return fs.readFileSync(`/proc/${pid}/stat`, "utf8").split(") ")[1][0] !== "Z"; } catch { return false; }
}
function read(name) { try { return fs.readFileSync(state + "/" + name, "utf8").trim(); } catch { return ""; } }
const paths = { root, home, state, config: home + "/config" };
if (!fs.existsSync(root)) {
  fs.mkdirSync(root, { recursive: true }); fs.mkdirSync(state, { recursive: true }); fs.mkdirSync(paths.config, { recursive: true });
  fs.cpSync(source + "/bin", root + "/bin", { recursive: true }); fs.writeFileSync(root + "/AGENTS.md", "fixture\n");
  fs.writeFileSync(root + "/bin/fm-sessionstart-nudge.sh", "#!/bin/bash\nexit 0\n", { mode: 0o700 });
  if (process.argv.includes("--exit")) {
    // Exercise the production arm/watcher and its real signal retirement,
    // not just the lightweight succession fixture used below.
    fs.writeFileSync(state + "/fixture.meta", "kind=scout\n");
  } else {
  fs.writeFileSync(root + "/bin/fm-supervision-lib.sh", 'fm_supervision_status() { FM_SUP_NEEDED=true; FM_SUP_QUEUE_PENDING=false; }\n');
  fs.writeFileSync(root + "/bin/fm-watch-arm.sh", `#!/bin/bash
set -eu
state="$FM_STATE_OVERRIDE"
if [ "\${1:-}" = --handling-delivered ]; then
  kill -0 "$4" || exit 1
  echo "pending:handling:$2" > "$state/.watcher-down"
  echo "confirm $2" >> "$state/order"
  exit 0
fi
count=$(cat "$state/count" 2>/dev/null || echo 0); count=$((count+1)); echo "$count" > "$state/count"
echo "$count predecessor=\${FM_WATCH_PREDECESSOR_ARM_PID:-}" >> "$state/launches"
echo "$$" > "$state/arm.pid"
old=$(cat "$state/watcher.pid" 2>/dev/null || true); [ -z "$old" ] || kill -TERM "$old" 2>/dev/null || true
sleep 1000 </dev/null >/dev/null 2>&1 & child=$!; echo "$child" > "$state/watcher.pid"
trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM INT HUP
if [ -f "$state/recovery-mode" ] && [ "$count" = 2 ]; then
  echo announced:downtime:fixture-recovery > "$state/.watcher-down"
  kill -TERM "$child"; wait "$child" 2>/dev/null || true
  echo 'check: rearm-resurface'
  exit 0
fi
if [ -n "\${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  echo "watcher: started pid=$child (beacon fresh) recovery-generation=fixture-recovery"
else
  echo "watcher: started pid=$child (beacon fresh)"
fi
wait "$child"
`, { mode: 0o700 });
  }
}
const me = owner.identity(process.pid);
const record = { version: 1, sessionID: "ses_provider_fixture", claimID: "f".repeat(48), ...paths, ownerPID: me.pid, ownerStart: me.start, hostBootID: me.boot, servicePID: me.pid, serviceStart: me.start, serviceURL: "http://127.0.0.1:12345", lifecycle: "claimed" };
process.env.FM_V2_ACTIVATION = JSON.stringify(record);
process.env.FM_HOME = home;
process.env.FM_STATE_OVERRIDE = state;
process.env.FM_ROOT_OVERRIDE = root;
process.env.FM_CONFIG_OVERRIDE = paths.config;
process.env.OPENCODE_SESSION_ID = record.sessionID;
fs.writeFileSync(state + "/.lock", String(me.pid));
let provider = false, commands = [], subscribes = 0, environments = 0, unregisters = 0;
function host(failAt) {
  const renders = [];
  return {
    renderApp() {
      provider = true; try { for (const render of renders) render(); } finally { provider = false; }
    },
    keymap: { layer(get) { assert.equal(provider, true, "Keymap.Provider is missing"); if (failAt === "render") throw new Error("fixture layer failure"); commands = get().commands; assert.equal(get().mode, "global"); } },
    ui: { slot(claim) {
      if (failAt === "slot") throw new Error("fixture slot registration failure");
      assert.equal(claim.append, "app");
      renders.push(claim.render);
      return () => { assert.equal(provider, false, "slot was disposed inside its own provider render"); unregisters++; renders.length = 0; commands = []; };
    }, toast: { show() {} } },
    client: {
      server: { info: async () => ({ pid: me.pid }) },
      session: {
        get: async () => ({ id: record.sessionID, location: { directory: root }, metadata: {} }),
        update: async () => { if (failAt === "activation") throw new Error("fixture activation failure"); },
        environment: async () => { environments++; },
        prompt: async input => { fs.appendFileSync(state + "/order", "admit\n"); return { id: input.id }; },
      },
      rpc: () => ({ bindingStatus: async () => ({ status: "valid" }) }),
      event: { async *subscribe({ signal }) {
        subscribes++;
        await new Promise(resolve => { if (signal.aborted) resolve(); else signal.addEventListener("abort", resolve, { once: true }); });
      } },
    },
  };
}
if (process.argv.includes("--exit")) {
  process.env.FM_POLL = "1";
  process.env.FM_HEARTBEAT = "999999";
  process.env.FM_CHECK_INTERVAL = "999999";
  const app = host(); await tui.setup(app); app.renderApp();
  assert.equal(commands[0].slash.name, "firstmate-rebind");
  await until(() => running(read(".watch.lock/pid")), "exit fixture never armed production watcher");
  const watcher = read(".watch.lock/pid");
  const children = fs.readFileSync(`/proc/${process.pid}/task/${process.pid}/children`, "utf8").trim().split(/\s+/);
  const arms = children.filter(pid => { try { return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes(root + "/bin/fm-watch-arm.sh"); } catch { return false; } });
  assert.equal(arms.length, 1, "exit fixture must own exactly one production arm");
  fs.writeFileSync(state + "/watcher.pid", watcher); fs.writeFileSync(state + "/arm.pid", arms[0]);
  process.exit(0); // Deliberately bypass the asynchronous plugin disposer.
}
let cleanup, coordinator;
try {
  assert.throws(() => host().keymap.layer(() => ({})), /Provider/); // fixture discriminates on the original cause
  for (const stage of ["slot", "render", "activation"]) {
    const app = host(stage), failed = await tui.setup(app);
    app.renderApp();
    assert.equal(typeof failed, "function"); await failed();
    assert.equal(globalThis[Symbol.for("firstmate.native.v2.tui.coordinator")], undefined);
    assert.equal(running(read("watcher.pid")), false);
  }
  const initialSubscriptions = subscribes;
  const app = host(); cleanup = await tui.setup(app); app.renderApp();
  assert.equal(typeof cleanup, "function");
  assert.equal(commands[0].slash.name, "firstmate-rebind");
  await until(() => subscribes === initialSubscriptions + 1 && running(read("watcher.pid")), "provider-host setup never subscribed/armed");
  // Register a private native endpoint for the actual rebind handler.
  fs.mkdirSync(lab + "/native"); fs.mkdirSync(lab + "/cli");
  owner.writePrivate(lab + "/native/service.json", { pid: me.pid, url: record.serviceURL, password: "fixture" });
  fs.writeFileSync(lab + "/cli/shuvcode", `#!/bin/bash\nprintf 'state %s\\n' '${lab}/native'\n`, { mode: 0o700 });
  process.env.PATH = lab + "/cli:" + process.env.PATH;
  await commands[0].run();
  assert.equal(owner.readRegistration(record.sessionID).lifecycle, "active");
  const pid = read("watcher.pid"); await cleanup(); cleanup = null;
  await until(() => !running(pid), "hot reload disposer left watcher alive");
  const before = environments; await delay(2100); assert.equal(environments, before, "cleanup left reconcile timer alive");
  const reloaded = host(); cleanup = await tui.setup(reloaded); reloaded.renderApp();
  await until(() => running(read("watcher.pid")), "hot reload did not rearm");
  await cleanup(); cleanup = null;
  assert.ok(unregisters >= 3);
  const exitLab = lab + "/exit", namespace = process.env.FM_V2_REGISTRY_NAMESPACE;
  const child = spawn(process.execPath, [process.argv[1], "--exit"], { env: { ...process.env, LAB: exitLab, FM_V2_REGISTRY_NAMESPACE: namespace + "-exit" }, stdio: ["ignore", "pipe", "pipe"] });
  let errors = ""; child.stderr.on("data", chunk => { errors += chunk; });
  assert.equal(await new Promise(resolve => child.on("close", resolve)), 0, errors);
  const exitedWatcher = fs.readFileSync(exitLab + "/home/state/watcher.pid", "utf8").trim(), exitedArm = fs.readFileSync(exitLab + "/home/state/arm.pid", "utf8").trim();
  assert.equal(owner.readPrivate(exitLab + "/home/state/.opencode-v2-owner.json").lifecycle, "retired");
  await until(() => !running(exitedWatcher) && !running(exitedArm), "synchronous owner exit orphaned arm/watcher");
  process.env.FM_V2_REGISTRY_NAMESPACE = namespace + "-exit"; owner.publish("cleanup-test-namespace", {}); process.env.FM_V2_REGISTRY_NAMESPACE = namespace;
  // Real arm SIGKILL with a surviving watcher: the retry must be ordinary,
  // resurface no-row recovery, then confirm a successor before admission.
  fs.writeFileSync(state + "/count", "0"); fs.writeFileSync(state + "/launches", ""); fs.writeFileSync(state + "/order", "");
  fs.writeFileSync(state + "/recovery-mode", "1"); fs.writeFileSync(state + "/.wake-queue", "");
  const admitted = [];
  const journal = createAdmissionJournal(paths, record.sessionID, async input => { admitted.push(input); fs.appendFileSync(state + "/order", "admit\n"); return { id: input.id }; });
  coordinator = createWatchArmCoordinator(paths, () => {}, { owns: () => true, needs: () => true, admission: journal, processIdentity: owner.identity });
  assert.equal(await coordinator.ensureArmed(record.sessionID), "armed");
  const orphan = read("watcher.pid"); process.kill(Number(read("arm.pid")), "SIGKILL");
  assert.equal(running(orphan), true);
  await until(() => admitted.length === 1, "arm SIGKILL failed to resurface/admit recovery wake");
  assert.match(read("launches"), /^2 predecessor=$/m);
  assert.match(read("launches"), /^3 predecessor=[0-9]+$/m);
  assert.equal(read("order"), "confirm fixture-recovery\nadmit");
  assert.match(admitted[0].text, /check: rearm-resurface/);
  const original = journal.prepare("unchanged", "wake", { recovery: { generation: "fixture-recovery" } });
  assert.equal(original.id, admitted[0].id); assert.equal(original.text, admitted[0].text);
  const other = journal.prepare("another recovery", "wake", { recovery: { generation: "next-generation" } });
  assert.notEqual(other.id, original.id);
  await assert.rejects(journal.deliver(other), /successor confirmation first/);
  assert.throws(() => journal.prepare("invalid"), /neither durable wake rows nor recovery generation/);
  const liveWatcher = read("watcher.pid"); await coordinator.cleanup(); coordinator = null;
  await until(() => !running(liveWatcher) && !running(orphan), "recovery cleanup left watcher alive");
  fs.rmSync(state + "/recovery-mode");
  let changedBirth = false;
  coordinator = createWatchArmCoordinator(paths, () => {}, { owns: () => true, needs: () => true,
    processIdentity: pid => { const value = owner.identity(pid); return changedBirth ? { ...value, start: "different-birth" } : value; } });
  assert.equal(await coordinator.ensureArmed(record.sessionID), "armed");
  const protectedArm = read("arm.pid"), protectedWatcher = read("watcher.pid");
  changedBirth = true; coordinator.cleanupSync(); await delay(100);
  assert.equal(running(protectedArm), true, "exit cleanup signaled a changed arm identity");
  assert.equal(running(protectedWatcher), true, "exit cleanup signaled a changed watcher identity");
  changedBirth = false; await coordinator.cleanup(); coordinator = null;
  await until(() => !running(protectedArm) && !running(protectedWatcher), "identity negative-control cleanup leaked");
  console.log("provider-scoped command, exception-safe setup/reload, synchronous exit and SIGKILL/no-row recovery passed");
} finally {
  try { await cleanup?.(); await coordinator?.cleanup(); }
  finally {
    if (running(read("arm.pid"))) process.kill(Number(read("arm.pid")), "SIGTERM");
    if (running(read("watcher.pid"))) process.kill(Number(read("watcher.pid")), "SIGTERM");
    owner.publish("cleanup-test-namespace", {});
  }
}
