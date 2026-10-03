import { identity, schema, publish, readRegistration, canonical, live, markerKey, writePrivate, registeredService, serviceURL } from "../../../bin/fm-opencode-v2-owner.mjs";
import { createWatchArmCoordinator } from "../lib/fm-watch-arm-v2.js";
import { createAdmissionJournal } from "./admission.js";
import { bindingRPC } from "./rpc.js";
import { eventSessionID, isIdleEvent } from "../lib/fm-plugin-v2.js";
import { runProcess } from "../lib/fm-plugin-common.js";
import { encodeFirstmateOperationalInput } from "../lib/fm-operational-input.js";
import { existsSync } from "node:fs";
import { createHash } from "node:crypto";

const slot = Symbol.for("firstmate.native.v2.tui.coordinator");

export function createFailureNotice(report, surface, { now = () => performance.now(), bound = 30000 } = {}) {
  let episode;
  function tick() {
    if (!episode || episode.notified || now() - episode.since < bound) return;
    episode.notified = true;
    surface(episode.reason);
  }
  return {
    failure(reason, { permanent = false } = {}) {
      report(reason);
      episode ||= { since: now(), notified: false };
      episode.reason = reason;
      if (permanent && !episode.notified) { episode.notified = true; surface(reason); }
      else tick();
    },
    recovered() { episode = undefined; },
    tick,
  };
}
const FAILURE_PROMPT_LIMIT = 8;

export async function supervisionNeeded(record, env = helperEnvironment(record)) {
  if (existsSync(`${record.state}/.afk`)) return false;
  const result = await runProcess("bash", ["-c", '. "$1/bin/fm-supervision-lib.sh" || exit 2; fm_supervision_status "$2" || exit 2; if [ "$FM_SUP_NEEDED" = true ] || [ "$FM_SUP_QUEUE_PENDING" = true ]; then echo needed; else echo idle; fi', "fm-native-v2", record.root, record.state], { cwd: record.root, env, timeout: 10000 });
  if (result.code !== 0 || !["needed", "idle"].includes(result.stdout.trim())) throw new Error("cannot evaluate canonical native supervision requirement");
  return result.stdout.trim() === "needed";
}

export function helperEnvironment(record) {
  const env = { ...process.env, FM_HOME: record.home, FM_ROOT_OVERRIDE: record.root, FM_STATE_OVERRIDE: record.state, FM_CONFIG_OVERRIDE: record.config,
    FM_V2_REGISTRY_NAMESPACE: process.env.FM_V2_REGISTRY_NAMESPACE || "default", FM_V2_SERVICE_URL: serviceURL(record.serviceURL) };
  for (const key of ["FM_V2_ACTIVATION", "OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD", "OPENCODE_SESSION_ID"]) delete env[key];
  return env;
}

export async function rebind(ctx, activation) {
  const current = readRegistration(activation.sessionID), own = identity(process.pid);
  for (const field of ["ownerPID", "ownerStart", "hostBootID", "sessionID", "claimID", "root", "home", "state", "config", "serviceURL"]) {
    if (current[field] !== activation[field]) throw new Error("rebind is not this immutable TUI claim");
  }
  if (own.pid !== current.ownerPID || own.start !== current.ownerStart || own.boot !== current.hostBootID) throw new Error("rebind caller is not the exact TUI owner");
  const service = identity((await ctx.client.server.info()).pid);
  const registered = registeredService(current.serviceURL);
  if (service.pid !== registered.pid || service.start !== registered.start || service.boot !== registered.boot) throw new Error("rebind service is not the frozen registered endpoint");
  return activate(ctx, { ...current, servicePID: service.pid, serviceStart: service.start, lifecycle: "claimed" });
}

export async function activate(ctx, activation) {
  const record = schema(activation);
  const own = identity(process.pid);
  if (record.ownerPID !== own.pid || record.ownerStart !== own.start || record.hostBootID !== own.boot) throw new Error("V2 activation is not for this exact TUI process");
  if (existsSync(`${record.home}/.fm-secondmate-home`) || existsSync(`${record.root}/.fm-secondmate-home`)) throw new Error("V2 secondmate activation is unsupported");
  const info = await ctx.client.session.get({ sessionID: record.sessionID });
  if (info.id !== record.sessionID || info.parentID || info.location?.directory !== record.root) throw new Error("V2 activation session is not this exact root");
  const service = identity((await ctx.client.server.info()).pid);
  if (service.pid !== record.servicePID || service.start !== record.serviceStart || service.boot !== record.hostBootID) throw new Error("connected service does not match V2 activation");
  // Reserve the serialized exact claim BEFORE changing session metadata, so
  // a refused second owner cannot overwrite the live owner's marker. The
  // server protects a registry entry even during marker publication.
  publish("claim", record);
  await ctx.client.session.update({ sessionID: record.sessionID, metadata: {
    ...info.metadata, [markerKey]: { version: 1, sessionID: record.sessionID, claimID: record.claimID },
  } });
  const status = await ctx.client.rpc(bindingRPC).bindingStatus({ sessionID: record.sessionID, claimID: record.claimID }, { location: { directory: record.root } });
  if (status.status !== "valid") throw new Error("execution service cannot validate this exact local V2 registration");
  // Explicit-server clients deliberately do not push their caller environment
  // in this native fork. Set only the frozen helper routing values once, after
  // authority is proven. They are checked observations, never the claim.
  await ctx.client.session.environment({ sessionID: record.sessionID, variables: helperEnvironment(record) });
  return Object.freeze(record);
}

export default { id: "firstmate.native.v2", async setup(ctx) {
  // Normal workers, children and observers are inert. The launcher, never
  // tab focus or first-event arrival, selects the immutable activation tuple.
  if (!process.env.FM_V2_ACTIVATION) return;
  if (globalThis[slot]) throw new Error("another native V2 coordinator is still active in this TUI");
  const requested = schema(JSON.parse(process.env.FM_V2_ACTIVATION));
  let activation = requested;
  try {
    const current = readRegistration(requested.sessionID);
    if (["ownerPID", "ownerStart", "hostBootID", "sessionID", "claimID", "root", "home", "state", "config", "serviceURL"].every(key => current[key] === requested[key])) activation = { ...current, lifecycle: "claimed" };
  } catch { /* activation itself still must pass full validation */ }
   let record = requested, coordinator, timer, unregisterUI, disposal;
   const reservation = {};
   globalThis[slot] = reservation;
   const abort = new AbortController();
   let stopped = false;
  const retireClaim = () => {
    const current = readRegistration(record.sessionID);
    if (current.claimID !== record.claimID || current.ownerPID !== process.pid || current.ownerStart !== record.ownerStart) throw new Error("obsolete TUI cannot retire a successor claim");
    if (current.lifecycle !== "retired") publish("retire", current);
  };
  // The installed TUI's final exit may finish before its asynchronous plugin
   // disposer. Signal only remembered arm/watcher process births synchronously;
   // the owned arm trap performs its ordinary retirement-to-downtime path.
   const exitFallback = () => {
     coordinator?.cleanupSync();
     try { retireClaim(); } catch (error) { console.error("V2 exit retirement: " + error.message); }
   };
   const cleanup = () => {
     if (disposal) return disposal;
     stopped = true;
     abort.abort();
     clearInterval(timer);
     let publicationError;
      const unregister = unregisterUI;
      unregisterUI = undefined; // host disposal is not required to be idempotent
      try { unregister?.(); } catch (error) { publicationError = error; }
     try { retireClaim(); } catch (error) { if (error.code !== "ENOENT") publicationError = error; }
     disposal = (async () => {
       try { await coordinator?.cleanup(); }
       finally {
         if (globalThis[slot] === coordinator || globalThis[slot] === reservation) delete globalThis[slot];
         process.removeListener("exit", exitFallback);
       }
       if (publicationError) throw publicationError;
     })();
     return disposal;
   };
   try {
   // Slot render runs within the host's Keymap.Provider; setup does not.
   // A deferred render failure also disposes already started resources.
   unregisterUI = ctx.ui.slot({ append: "app", render() {
     if (stopped) return null;
     try {
       ctx.keymap.layer(() => ({ mode: "global", commands: [{ id: "firstmate.rebind", title: "Rebind Firstmate execution service", palette: true, slash: { name: "firstmate-rebind" }, run: async () => {
         if (stopped || !coordinator) return;
         try {
           await coordinator.cleanup();
           await rebind(ctx, record);
           if (stopped) return;
           coordinator = createWatchArmCoordinator(paths, () => {}, coordinatorOptions);
           globalThis[slot] = coordinator;
           await reconcile();
           ctx.ui.toast?.show({ variant: "success", message: "Exact lead execution service rebind verified." });
         } catch (error) { failure(error.message); }
       } }] }));
     } catch (error) {
       console.error("V2 command registration: " + error.message);
       stopped = true;
       queueMicrotask(() => { void cleanup().catch(error => console.error("V2 setup cleanup: " + error.message)); });
     }
     return null;
   } });
    if (stopped) return cleanup; // render failure already scheduled disposal
   record = await activate(ctx, activation);
   if (stopped) { retireClaim(); return cleanup; }
   process.once("exit", exitFallback);
   const paths = { root: record.root, home: record.home, state: record.state, config: record.config };
  let reconcileInFlight;
  let lastFailure = "";
  const surfaced = new Set();
   const notices = createFailureNotice(reason => {
    if (stopped) return;
    if (lastFailure === reason) return;
    lastFailure = reason;
    console.error(reason);
    writePrivate(`${record.state}/.opencode-v2-failure.json`, { version: 1, sessionID: record.sessionID, claimID: record.claimID, reason: String(reason).slice(0, 12000) });
   }, reason => {
    if (stopped) return;
    const text = String(reason).slice(0, 4000);
    if (surfaced.has(text) || surfaced.size >= FAILURE_PROMPT_LIMIT) return;
    surfaced.add(text);
    try { ctx.ui.toast?.show({ variant: "error", message: "Firstmate watcher failure: " + text }); } catch (error) { console.error("V2 failure toast: " + error.message); }
    void (async () => {
      const prompt = await encodeFirstmateOperationalInput(record.root, "watcher", `WATCHER FAILURE - native V2 supervision reported a failure; drain queued wakes with bin/fm-wake-drain.sh, inspect this reason, and probe recovery manually with bin/fm-watch-arm.sh if continuity is not restored.\n\n${text}`);
      await journal.deliver(journal.prepare(prompt, "failure:" + record.claimID + ":" + createHash("sha256").update(text).digest("hex")));
    })().catch(error => console.error("V2 failure prompt: " + error.message));
   });
   const failure = (reason, detail) => { if (!stopped) notices.failure(reason, detail); };
   const failureFromError = error => failure(error.message, { permanent: error.nonRecoverable === true });
  const owns = () => {
    try {
      const current = live(readRegistration(record.sessionID));
      if (current.claimID !== record.claimID || current.ownerPID !== process.pid) return false;
      canonical(current);
      return true;
    } catch { return false; }
  };
  const validClaim = () => {
    try { const value = live(readRegistration(record.sessionID)); canonical(value, false); return !stopped && value.claimID === record.claimID && value.ownerPID === process.pid; }
    catch { return false; }
  };
  const journal = createAdmissionJournal(paths, record.sessionID, input => ctx.client.session.prompt(input, { signal: AbortSignal.any([abort.signal, AbortSignal.timeout(10000)]) }), failure, { valid: validClaim, signal: abort.signal });
   const coordinatorOptions = { owns, admission: journal, failure, needs: () => supervisionNeeded(record), processIdentity: identity };
   coordinator = createWatchArmCoordinator(paths, () => {}, coordinatorOptions);
  globalThis[slot] = coordinator;
  const env = { ...helperEnvironment(record), OPENCODE_SESSION_ID: record.sessionID };

  async function reconcile() {
    if (stopped || reconcileInFlight) return;
    reconcileInFlight = (async () => {
      if (!validClaim()) {
        await coordinator.cleanup();
        throw Object.assign(new Error("V2 owner/service proof is stale; explicitly rebind before continuing"), { nonRecoverable: true });
      }
      // Stock clients replace the session environment on tab navigation. Only
      // this proven immutable TUI refreshes its frozen routing, never observers.
      await ctx.client.session.environment({ sessionID: record.sessionID, variables: helperEnvironment(record) });
      if (!owns()) {
        const status = await ctx.client.rpc(bindingRPC).bindingStatus({ sessionID: record.sessionID, claimID: record.claimID }, { location: { directory: record.root } });
        if (status.status !== "valid") throw Object.assign(new Error("V2 exact lead registration is stale; explicitly rebind before continuing"), { nonRecoverable: true });
        for (const pending of journal.pending()) {
          if (pending.kind === "startup:" + record.claimID) await journal.deliver(pending);
        }
        failure("V2 supervision ownership is unavailable; automatic reconciliation is continuing");
        return;
      }
      const current = readRegistration(record.sessionID);
      if (current.lifecycle !== "active") publish("claim", { ...current, lifecycle: "active" });
      const armStatus = await coordinator.ensureArmed(record.sessionID);
      await coordinator.resumePending(record.sessionID);
      const pending = journal.pending().filter(value => !value.kind.startsWith("failure:"));
      if (pending.length) failure("V2 retained admission remains undelivered; automatic recovery is continuing");
      else if (["armed", "existing", "not-needed"].includes(armStatus)) notices.recovered();
    })();
    try { await reconcileInFlight; } finally { reconcileInFlight = null; }
  }
  try {
    const proof = await runProcess("node", [`${record.root}/bin/fm-opencode-v2-owner.mjs`, "helper", record.state, "acquire"], { cwd: record.root, env, timeout: 10000 });
    if (proof.code !== 0) throw new Error("V2 startup helper proof failed: " + proof.stderr.trim());
    const nudge = await runProcess(`${record.root}/bin/fm-sessionstart-nudge.sh`, [], { cwd: record.root, env, timeout: 10000 });
    if (nudge.code !== 0) throw new Error("V2 startup nudge failed");
    if (nudge.stdout.trim()) await journal.deliver(journal.prepare(nudge.stdout.trim(), "startup:" + record.claimID));
    await reconcile();
  } catch (error) { failureFromError(error); }

   if (stopped) return cleanup;
   timer = setInterval(() => { void reconcile().catch(failureFromError).finally(() => notices.tick()); }, 2000);
  timer.unref();
  void (async () => {
    try {
      for await (const event of ctx.client.event.subscribe({ signal: abort.signal })) {
        if (stopped || eventSessionID(event) !== record.sessionID) continue;
        if (!isIdleEvent(event)) continue;
        // Idle/interrupted alone never admits a continuation. The watcher is
        // restored here; only its genuine durable wake journal admits input.
        await reconcile();
      }
    } catch (error) { if (!abort.signal.aborted) failure("V2 event stream interrupted: " + error.message); }
  })();

   } catch (error) {
     console.error("V2 setup failed: " + error.message);
     try { await cleanup(); } catch (error) { console.error("V2 setup cleanup: " + error.message); }
   }
   return cleanup;
} };
