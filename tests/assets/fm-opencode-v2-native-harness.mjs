// Process stand-ins for OpenCode V2 shared-service acceptance tests.
//
// Roles (all import the production modules from CODE_ROOT, never copies):
//   service <code-root> <socket> <sessions.json>
//       The execution service stand-in. Its own pid is the registered service
//       pid, it hosts the production server entry's exported guard and
//       bindingStatus functions (so their process.pid checks see the service),
//       and it parents model shells, which therefore descend from it exactly as
//       real shell tools descend from `serve --service`. A model shell gets the
//       session's pushed environment when one was pushed, otherwise the
//       service's own environment (shuvcode core/src/shell.ts).
//   owner <code-root> <socket> <session> <root> <home> <state> <config>
//       A stand-in activated owner: publishes an exact claim for itself through
//       the production owner library, prints the record, stays alive, and
//       retires on SIGUSR1.
//   tui <code-root> <socket> <spec.json> <out.json>
//       Runs the production TUI entry's setup with a genuine activation for
//       this exact process and the stand-in service, then executes the spec's
//       steps and records admissions, metadata, environment pushes and failures.
//   call <socket> <json>
//       One request to a running service; prints the JSON reply.
// Sessions live in sessions.json: {id: Session.Info}. The service re-reads it on
// every request so tests can edit snapshots between steps.
import net from "node:net";
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [role, ...args] = process.argv.slice(2);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function request(socket, message, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socket);
    let data = "";
    const timer = setTimeout(() => { client.destroy(); reject(new Error("service request timed out")); }, timeoutMs);
    client.on("connect", () => client.end(JSON.stringify(message) + "\n"));
    client.on("data", (chunk) => (data += chunk));
    client.on("end", () => { clearTimeout(timer); try { resolve(JSON.parse(data)); } catch (error) { reject(error); } });
    client.on("error", (error) => { clearTimeout(timer); reject(error); });
  });
}

function sessionAPI(sessionsFile, environments) {
  const read = () => JSON.parse(readFileSync(sessionsFile, "utf8"));
  return {
    async get({ sessionID }) {
      const all = read();
      if (!all[sessionID]) throw new Error("session not found");
      return all[sessionID];
    },
    async update({ sessionID, metadata }) {
      const all = read();
      if (!all[sessionID]) throw new Error("session not found");
      if (metadata !== undefined) all[sessionID].metadata = metadata;
      writeFileSync(sessionsFile, JSON.stringify(all));
    },
    async environment({ sessionID, variables }) {
      if (variables !== undefined) environments.set(sessionID, { ...variables });
      return environments.get(sessionID);
    },
  };
}

async function serviceRole([codeRoot, socket, sessionsFile]) {
  // Present the shared service's process shape to ancestry walks: comm
  // `shuvcode` plus the whole `--service` token in the arguments.
  try { writeFileSync("/proc/self/comm", "shuvcode"); } catch {}
  const server = await import(pathToFileURL(`${codeRoot}/.opencode/plugins/fm-native-v2/server.js`).href);
  const environments = new Map();
  const api = sessionAPI(sessionsFile, environments);
  // Native shell inventory (`shuvcode api shell.list`): every model shell this
  // service spawned, with the server-set session metadata and its kernel pid.
  // Model shells reach it through a `shuvcode` on PATH that queries this
  // service, as a real shell's `shuvcode api` reaches its own service.
  const shells = new Map();
  const { mkdtempSync, chmodSync } = await import("node:fs");
  const apiBin = mkdtempSync(`${socket}.bin-`);
  writeFileSync(`${apiBin}/shuvcode`, `#!/usr/bin/env bash
[ "$1" = api ] || { echo "stand-in shuvcode supports only api" >&2; exit 2; }
exec ${JSON.stringify(process.execPath)} ${JSON.stringify(process.argv[1])} call ${JSON.stringify(socket)} "$(printf '{"op":"api","operation":"%s"}' "$2")"
`);
  chmodSync(`${apiBin}/shuvcode`, 0o755);
  const handlers = {
    pid: async () => ({ pid: process.pid }),
    bindingStatus: async ({ input }) => server.bindingStatus(api, input),
    guardScope: async ({ sessionID }) => {
      const scope = await server.guardScope(api, sessionID);
      return { registered: scope.registered, error: scope.error || null, claimID: scope.record?.claimID || null };
    },
    denyReason: async ({ event, env }) => {
      const saved = { ...process.env };
      if (env) for (const [key, value] of Object.entries(env)) value === null ? delete process.env[key] : (process.env[key] = value);
      try { return { reason: await server.denyReason(api, event) }; }
      catch (error) { return { thrown: String(error?.message ?? error) }; }
      finally { for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key]; Object.assign(process.env, saved); }
    },
    environment: async ({ sessionID, variables }) => ({ variables: await api.environment({ sessionID, variables }) ?? null }),
    api: async ({ operation }) => {
      if (operation === "server.info") return { pid: process.pid };
      if (operation === "shell.list") return { data: [...shells.entries()].map(([pid, sessionID]) => ({ pid, status: "running", metadata: { sessionID } })) };
      return { error: "unsupported operation" };
    },
    // A model shell tool: the session's pushed environment replaces the
    // service environment, and the server then sets OPENCODE_SESSION_ID.
    shell: ({ sessionID, command, extraEnv }) => new Promise((resolve) => {
      const base = environments.get(sessionID) ?? process.env;
      const env = { ...base, TERM: "xterm-256color", OPENCODE_TERMINAL: "1", OPENCODE_SESSION_ID: sessionID, ...(extraEnv || {}) };
      env.PATH = `${apiBin}:${env.PATH || "/usr/local/bin:/usr/bin:/bin"}`;
      const child = spawn("/bin/bash", ["-c", command], { cwd: codeRoot, env, stdio: ["ignore", "pipe", "pipe"] });
      shells.set(child.pid, sessionID);
      let stdout = "", stderr = "";
      child.stdout.on("data", (c) => (stdout += c));
      child.stderr.on("data", (c) => (stderr += c));
      child.on("close", (code, signal) => { shells.delete(child.pid); resolve({ code, signal, stdout, stderr }); });
    }),
  };
  const srv = net.createServer({ allowHalfOpen: true }, (conn) => {
    let data = "";
    conn.on("data", (chunk) => {
      data += chunk;
      if (!data.endsWith("\n")) return;
      const message = JSON.parse(data);
      Promise.resolve(handlers[message.op]?.(message) ?? { error: "unknown op" })
        .catch((error) => ({ error: String(error?.message ?? error) }))
        .then((reply) => conn.end(JSON.stringify(reply)));
    });
  });
  srv.listen(socket, () => console.log(JSON.stringify({ ready: true, pid: process.pid })));
  process.on("SIGTERM", () => { srv.close(); process.exit(0); });
}

async function ownerRole([codeRoot, socket, sessionID, root, home, state, config]) {
  const owner = await import(pathToFileURL(`${codeRoot}/bin/fm-opencode-v2-owner.mjs`).href);
  const { randomBytes } = await import("node:crypto");
  const self = owner.identity(process.pid);
  const service = owner.identity((await request(socket, { op: "pid" })).pid);
  const record = owner.publish("claim", {
    version: 1, sessionID, claimID: randomBytes(24).toString("hex"), root, home, state, config,
    ownerPID: self.pid, ownerStart: self.start, hostBootID: self.boot,
    servicePID: service.pid, serviceStart: service.start, lifecycle: "claimed",
  });
  console.log(JSON.stringify(record));
  process.on("SIGUSR1", () => {
    try { console.log(JSON.stringify({ retired: owner.publish("retire", owner.readRegistration(sessionID)) })); }
    catch (error) { console.log(JSON.stringify({ retireError: String(error.message) })); }
  });
  process.on("SIGTERM", () => process.exit(0));
  setInterval(() => {}, 1 << 30);
}

async function tuiRole([codeRoot, socketFile, specFile, outFile]) {
  const spec = JSON.parse(readFileSync(specFile, "utf8"));
  const owner = await import(pathToFileURL(`${codeRoot}/bin/fm-opencode-v2-owner.mjs`).href);
  const { randomBytes } = await import("node:crypto");
  // socketFile holds the current service socket path so a test can replace the
  // service (restart) under a live owner.
  const socket = () => readFileSync(socketFile, "utf8").trim();
  const self = owner.identity(spec.foreignOwnerPid || process.pid);
  const svcPid = (await request(socket(), { op: "pid" })).pid;
  const service = owner.identity(svcPid);
  const claimID = spec.claimID || randomBytes(24).toString("hex");
  const activation = {
    version: 1, sessionID: spec.sessionID, claimID, root: spec.root, home: spec.home, state: spec.state, config: spec.config,
    ownerPID: self.pid, ownerStart: self.start, hostBootID: self.boot, servicePID: service.pid, serviceStart: service.start, lifecycle: "claimed",
  };
  const record = { activation, prompts: [], admitted: [], metadataWrites: 0, environmentPushes: [], failures: [], steps: [], claimID };
  const ids = new Set();
  let rejectPrompts = spec.rejectPrompts || 0;
  let outageUntil = 0;
  let lostAcks = spec.lostAckPrompts || 0;
  const events = [];
  let notify = null;
  let streamBroken = false;
  const commands = new Map();
  // Manual reconcile clock: the TUI's periodic reconcile (2 s interval) is
  // captured instead of scheduled, so a case can tell an event-triggered
  // reconcile from the timer fallback and fire the fallback explicitly.
  const timers = [];
  if (spec.manualTimer) {
    const realSetInterval = globalThis.setInterval, realClearInterval = globalThis.clearInterval;
    globalThis.setInterval = (fn, ms, ...rest) => {
      if (ms !== 2000) return realSetInterval(fn, ms, ...rest);
      const handle = { manual: true, fn, unref() { return handle; }, ref() { return handle; } };
      timers.push(handle);
      return handle;
    };
    globalThis.clearInterval = (handle) => {
      if (handle?.manual) { const i = timers.indexOf(handle); if (i >= 0) timers.splice(i, 1); return; }
      realClearInterval(handle);
    };
  }
  const identityOf = (pid) => { try { const id = owner.identity(pid); return `${id.pid} ${id.start}`; } catch { return `${pid} 0`; } };
  const watcherLive = () => {
    try { const pid = Number(readFileSync(`${spec.state}/.watch.lock/pid`, "utf8").trim()); process.kill(pid, 0); return true; } catch { return false; }
  };
  const ctx = {
    keymap: { layer(fn) { for (const command of fn().commands || []) commands.set(command.slash?.name || command.id, command); return () => {}; } },
    ui: { toast: { show(t) { record.toasts = [...(record.toasts || []), t]; } } },
    client: {
      session: {
        async get({ sessionID }) {
          const info = JSON.parse(readFileSync(spec.sessionsFile, "utf8"))[sessionID];
          if (!info) throw new Error("session not found");
          return info;
        },
        async update({ sessionID, metadata }) {
          record.metadataWrites += 1;
          const all = JSON.parse(readFileSync(spec.sessionsFile, "utf8"));
          all[sessionID].metadata = metadata;
          writeFileSync(spec.sessionsFile, JSON.stringify(all));
        },
        async environment({ sessionID, variables }) {
          record.environmentPushes.push({ at: Date.now(), keys: Object.keys(variables || {}).sort() });
          return (await request(socket(), { op: "environment", sessionID, variables })).variables;
        },
        async prompt(input) {
          const marker = spec.markerFile ? (() => { try { return readFileSync(spec.markerFile, "utf8").trim(); } catch { return null; } })() : undefined;
          record.prompts.push({ ...input, at: Date.now(), marker, watcherLive: spec.state ? watcherLive() : undefined });
          // Fault injection applies only to prompts matching spec.faultMatch
          // (default: every prompt), e.g. watcher wakes but not the nudge.
          const faulty = new RegExp(spec.faultMatch || ".").test(input.text);
          if (faulty && Date.now() < outageUntil) throw new Error("admission outage");
          if (faulty && rejectPrompts > 0) { rejectPrompts -= 1; throw new Error("admission rejected"); }
          if (!ids.has(input.id)) { ids.add(input.id); record.admitted.push({ ...input, at: Date.now() }); }
          if (faulty && lostAcks > 0) { lostAcks -= 1; throw new Error("acknowledgement lost"); }
          return { id: input.id };
        },
      },
      server: { async info() { return { pid: (await request(socket(), { op: "pid" })).pid }; } },
      rpc() { return { bindingStatus: async (input) => request(socket(), { op: "bindingStatus", input }) }; },
      event: {
        subscribe({ signal } = {}) {
          return { async *[Symbol.asyncIterator]() {
            while (!signal?.aborted) {
              if (streamBroken) throw new Error("native event stream lost");
              if (events.length) { yield events.shift(); continue; }
              await new Promise((resolve) => { notify = resolve; signal?.addEventListener("abort", resolve, { once: true }); });
            }
          } };
        },
      },
    },
  };
  if (!spec.inactive) process.env.FM_V2_ACTIVATION = JSON.stringify(activation);
  else delete process.env.FM_V2_ACTIVATION;
  if (spec.failureFile !== false) {
    const original = console.error;
    console.error = (...items) => { record.failures.push(items.map(String).join(" ")); original.apply(console, items); };
  }
  const tui = await import(pathToFileURL(`${codeRoot}/.opencode/plugins/fm-native-v2/tui.js`).href + (spec.reloadTag ? `?r=${spec.reloadTag}` : ""));
  let cleanup = null;
  try { cleanup = await tui.default.setup(ctx); record.setup = "ok"; }
  catch (error) { record.setup = "threw: " + String(error?.message ?? error); }
  for (const step of spec.steps || []) {
    const entry = { step: step.do };
    if (step.do === "sleep") await sleep(step.ms);
    else if (step.do === "event") { events.push(step.event); notify?.(); }
    else if (step.do === "shell") Object.assign(entry, await request(socket(), { op: "shell", sessionID: step.sessionID || spec.sessionID, command: step.command, extraEnv: step.extraEnv }, 60000));
    else if (step.do === "observer-push") Object.assign(entry, await request(socket(), { op: "environment", sessionID: spec.sessionID, variables: step.variables }));
    else if (step.do === "write") writeFileSync(step.path, step.text);
    else if (step.do === "outage") { outageUntil = Date.now() + step.ms; entry.until = outageUntil; }
    else if (step.do === "stream-error") { streamBroken = true; notify?.(); }
    else if (step.do === "tick") { entry.timers = timers.length; for (const t of [...timers]) t.fn(); await sleep(50); }
    else if (step.do === "wait") {
      // Bounded readiness polling; entry.ok records whether the condition held.
      const deadline = Date.now() + (step.timeoutMs || 20000);
      const holds = async () => {
        if (step.until === "watcher") return watcherLive();
        if (step.until === "no-watcher") return !watcherLive();
        if (step.until === "lifecycle") { try { return owner.readRegistration(spec.sessionID).lifecycle === step.value; } catch { return false; } }
        if (step.until === "prompted") return record.prompts.filter((a) => new RegExp(step.match || ".").test(a.text)).length >= (step.count || 1);
        if (step.until === "admitted") return record.admitted.filter((a) => new RegExp(step.match || ".").test(a.text)).length >= (step.count || 1);
        if (step.until === "file") return existsSync(step.path);
        if (step.until === "lock") { try { return readFileSync(`${spec.state}/.lock`, "utf8").trim() === String(process.pid); } catch { return false; } }
        if (step.until === "shell-ok") return (await request(socket(), { op: "shell", sessionID: step.sessionID || spec.sessionID, command: step.command, extraEnv: step.extraEnv }, 60000)).code === 0;
        throw new Error("unknown wait condition " + step.until);
      };
      let ok = false;
      const started = Date.now();
      while (Date.now() < deadline) { if (await holds()) { ok = true; break; } await sleep(step.pollMs || 200); }
      Object.assign(entry, { until: step.until, ok, waitedMs: Date.now() - started });
    }
    else if (step.do === "cleanup") { if (cleanup) { try { await cleanup(); entry.ok = true; } catch (error) { entry.threw = String(error.message); } cleanup = null; } }
    else if (step.do === "setup-again") {
      const again = await import(pathToFileURL(`${codeRoot}/.opencode/plugins/fm-native-v2/tui.js`).href + `?r=${Date.now()}`);
      try { cleanup = await again.default.setup(ctx); entry.ok = true; } catch (error) { entry.threw = String(error.message); }
    } else if (step.do === "restart-service") {
      // Replace the execution service under the live owner: new pid, new
      // in-memory session environments, same durable sessions.
      const old = (await request(socket(), { op: "pid" })).pid;
      const next = socket() + ".r" + Date.now();
      const child = spawn(process.env.V2_SERVICE_EXEC || process.execPath, [process.argv[1], "service", codeRoot, next, spec.sessionsFile, "--service"], { detached: true, stdio: ["ignore", "pipe", "ignore"] });
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("replacement service did not become ready within 20 s")), 20000);
        child.on("error", (e) => { clearTimeout(timer); reject(e); });
        child.on("exit", (code) => { clearTimeout(timer); reject(new Error("replacement service exited " + code)); });
        child.stdout.on("data", (c) => { if (String(c).includes('"ready":true')) { clearTimeout(timer); resolve(); } });
      }).catch((error) => { entry.error = String(error.message); });
      if (spec.pidsFile) writeFileSync(spec.pidsFile, readFileSync(spec.pidsFile, "utf8") + identityOf(child.pid) + "\n");
      child.unref();
      writeFileSync(socketFile, next);
      try { process.kill(old, "SIGTERM"); } catch {}
      entry.oldPid = old;
      entry.newPid = child.pid;
    } else if (step.do === "command") {
      const command = commands.get(step.name);
      if (!command) entry.error = "command not registered";
      else { try { await command.run(); entry.ok = true; } catch (error) { entry.threw = String(error.message); } }
    } else if (step.do === "registration") {
      try { entry.record = owner.readRegistration(spec.sessionID); } catch (error) { entry.error = String(error.message); }
    }
    entry.at = Date.now();
    record.steps.push(entry);
  }
  if (cleanup && spec.cleanupAtEnd !== false) { try { await cleanup(); record.cleanup = "ok"; } catch (error) { record.cleanup = "threw: " + error.message; } }
  writeFileSync(outFile, JSON.stringify(record));
  process.exit(0);
}

if (role === "service") await serviceRole(args);
else if (role === "owner") await ownerRole(args);
else if (role === "tui") await tuiRole(args);
else if (role === "call") console.log(JSON.stringify(await request(args[0], JSON.parse(args[1]), 90000)));
else { console.error("usage: service|owner|tui|call"); process.exit(2); }
