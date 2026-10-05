// Exact shared-session reconciliation. CLI: status|interrupt|teardown|discard|started RECORD WORKTREE.
// started RECORD WORKTREE GENERATION verifies a secondmate launch against its
// current spawn generation and pre-launch last-message ID, never a prior launch.
// session.get establishes placement/model; session.active is the native execution
// owner (session.get has no execution-status field on the qualified fork).
// The sidecar is published before prompt admission; busy evidence contradicts
// an absent record and must be checked before calling the task unrecorded.
// A gone process can leave a durable claim that the next server resumes.
// Malformed records and ambiguous/unverifiable live processes still refuse.
import { readPrivate, writePrivate, nativeAPI, identity, serviceURL, registeredService } from "./fm-opencode-v2-owner.mjs";
import * as fs from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout } from "node:timers/promises";
import { spawnSync } from "node:child_process";

function incarnationGone(record) {
  try {
    const current = identity(record.servicePID);
    return current.start !== record.serviceStart || current.boot !== record.hostBootID;
  } catch (error) {
    if (error.code === "ESRCH" || error.code === "ENOENT" && [`/proc/${record.servicePID}/stat`, `/proc/${record.servicePID}`].includes(error.path)) return true;
    throw error; // permission, unsupported-host, foreign-user or unreadable proof
  }
}

function absentSnapshot(file) {
  const busyFile = file.replace(/\.opencode-v2-session\.json$/, ".busy-state");
  if (busyFile === file) throw new Error("absent V2 sidecar has no task binding for busy-state verification");
  let busy;
  try { busy = readPrivateText(busyFile); }
  catch (error) { if (error.code !== "ENOENT") throw error; }
  if (busy !== undefined && (!/^v1\s/.test(busy) || (busy.match(/(?:^|\s)state=(?:busy|idle|unknown)(?=\s|$)/g) || []).length !== 1)) throw new Error("REFUSED: absent V2 sidecar has an invalid busy record");
  if (busy && /(?:^|\s)state=busy(?:\s|$)/.test(busy)) return { recorded: false, executing: null, busyFile };
  return { recorded: false, executing: false };
}

function successorTiming(binding) {
  const current = identity(binding.servicePID);
  if (current.start !== binding.serviceStart || current.boot !== binding.hostBootID) throw new Error("successor changed while checking settlement");
  const ticks = spawnSync("getconf", ["CLK_TCK"], { encoding: "utf8", timeout: 1000 });
  const hz = Number(ticks.stdout?.trim()), uptime = Number(fs.readFileSync("/proc/uptime", "utf8").split(" ")[0]);
  if (ticks.status !== 0 || !Number.isFinite(hz) || hz <= 0 || !Number.isFinite(uptime)) throw new Error("cannot verify successor uptime");
  const age = (uptime - Number(current.start) / hz) * 1000;
  return { age };
}

// Test seams exercise the same criterion; production callers always use real
// kernel time, exact-service API reads and a one-second sample separation.
export async function settledSuccessor(snapshot, deps = {}) {
  const timing = (deps.timing || successorTiming)(snapshot.binding);
  if (timing.age < 30000 || snapshot.executing) return false;
  await (deps.wait || setTimeout)(1000);
  const active = (deps.api || nativeAPI)(snapshot.binding, "session.active").data;
  if (!active || typeof active !== "object" || Array.isArray(active) || Object.values(active).some(value => value?.type !== "running")) throw new Error("invalid successor settlement snapshot");
  if (Object.hasOwn(active, snapshot.record.sessionID)) return false;
  const messages = (deps.api || nativeAPI)(snapshot.binding, "session.message.list", [...snapshot.args, "--param", "order=desc", "--param", "limit=1"]).data;
  if (!Array.isArray(messages) || messages.length !== 1) return false;
  const latest = messages[0], completed = latest?.time?.completed;
  if (latest?.type === "idle") return ["succeeded", "failed", "interrupted"].includes(latest.outcome) &&
    Number.isFinite(latest.time?.created) && latest.time.created <= Date.now();
  return latest?.type === "assistant" && latest.finish === "stop" && !latest.error &&
    Number.isFinite(completed) && completed <= Date.now();
}

function readPrivateText(file) {
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.isSymbolicLink() || st.uid !== process.getuid() || st.nlink !== 1 || st.mode & 0o077 || st.size > 16384) throw new Error("unsafe V2 busy record");
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try { return fs.readFileSync(fd, "utf8"); } finally { fs.closeSync(fd); }
}

export function workerSnapshot(file, worktree, retry = true) {
  let record;
  try { const st = fs.lstatSync(file); if (st.isSymbolicLink()) throw new Error("unsafe V2 session sidecar symlink"); }
  catch (error) { if (error.code !== "ENOENT") throw error; return absentSnapshot(file); }
  record = readPrivate(file); // disappearing or unreadable existing proof refuses
  if (
    record.version !== 1 || !/^ses_[A-Za-z0-9_-]{1,160}$/.test(record.sessionID) || record.location?.directory !== resolve(worktree) ||
    typeof record.model?.providerID !== "string" || !record.model.providerID || typeof record.model?.id !== "string" || !record.model.id ||
    record.model.variant !== undefined && (typeof record.model.variant !== "string" || !record.model.variant) ||
    !Number.isSafeInteger(record.servicePID) || record.servicePID < 2 || typeof record.serviceStart !== "string" || !/^(0|[1-9][0-9]*)$/.test(record.serviceStart) ||
    typeof record.hostBootID !== "string" || !/^[a-f0-9-]{36}$/.test(record.hostBootID) || serviceURL(record.serviceURL) !== record.serviceURL
  ) throw new Error("invalid recorded V2 worker binding");
  let binding = record, successor = false;
  if (incarnationGone(record)) {
    let service;
    try { service = registeredService(record.serviceURL); }
    catch (error) {
      if (!["ENOENT", "ESRCH"].includes(error.code) && !/unregistered native service endpoint/.test(error.message)) throw error;
      return { record, recorded: true, executing: null, incarnation: "unverifiable" };
    }
    binding = { ...record, servicePID: service.pid, serviceStart: service.start, hostBootID: service.boot };
    successor = true;
  }
  const args = ["--param", `sessionID=${record.sessionID}`, "--param", `location[directory]=${record.location.directory}`];
  try {
    if (nativeAPI(binding, "server.info").pid !== binding.servicePID) throw new Error("worker endpoint belongs to a different service");
    const info = nativeAPI(binding, "session.get", args).data;
    if (info?.id !== record.sessionID || info.parentID || info.location?.directory !== record.location.directory || info.model?.providerID !== record.model.providerID || info.model?.id !== record.model.id || (info.model?.variant || "default") !== (record.model.variant || "default")) throw new Error(`recorded V2 worker session ${record.sessionID} changed identity/location/model`);
    const active = nativeAPI(binding, "session.active").data;
    if (!active || typeof active !== "object" || Array.isArray(active) || Object.values(active).some(value => value?.type !== "running")) throw new Error("invalid native execution snapshot");
    return { record, binding, recorded: true, args, executing: Object.hasOwn(active, record.sessionID), incarnation: successor ? "successor" : "original" };
  } catch (error) {
    // A stop/restart can race the initial proof or any API request. Recheck
    // process birth, never interpret an API/registration failure alone as idle.
    if (retry && incarnationGone(binding)) return workerSnapshot(file, worktree, false);
    throw error;
  }
}

export async function reconcileWorker(action, file, worktree) {
  if (!["status", "teardown", "interrupt", "discard"].includes(action)) throw new Error("invalid V2 worker reconciliation action");
  let snapshot = workerSnapshot(file, worktree);
  const stoppedVerdict = value => {
    if (value.recorded === false) {
      if (value.executing === null) {
        const warning = `absent V2 session sidecar conflicts with busy record ${value.busyFile}; restore the binding and reconcile, or use explicit --force discard accepting possible resumed execution`;
        if (action !== "status" && action !== "discard") throw new Error("REFUSED: " + warning);
        if (action === "discard") console.error("WARNING: forced discard without confirmed native cancellation: " + warning);
        return { executing: null, recorded: false, cancellation: "unconfirmed", busyFile: value.busyFile };
      }
      console.error("V2 task has no recorded native session; no busy record reports execution.");
      return { executing: false, recorded: false };
    }
    if (value.incarnation === "unverifiable") {
      const warning = "native service unavailable; an orphaned turn may resume at the next service start. Start the frozen-endpoint service and retry, or use explicit --force discard";
      if (action !== "discard" && action !== "status") throw new Error("REFUSED: " + warning);
      if (action === "discard") console.error("WARNING: forced discard without confirmed native cancellation: " + warning);
      return { sessionID: value.record.sessionID, executing: null, recorded: true, incarnation: "unverifiable", cancellation: "unconfirmed" };
    }
  };
  const stopped = stoppedVerdict(snapshot);
  if (stopped) return stopped;
  if (action === "status") return { sessionID: snapshot.record.sessionID, executing: snapshot.incarnation === "successor" && !snapshot.executing ? null : snapshot.executing, observedExecuting: snapshot.executing, incarnation: snapshot.incarnation, cancellation: snapshot.incarnation === "successor" ? "unproven" : "not-requested" };
  if (action === "teardown") {
    if (snapshot.executing) throw new Error(`REFUSED: exact V2 worker ${snapshot.record.sessionID} is still executing; pane death is not stopped execution`);
    if (snapshot.incarnation !== "successor") return { sessionID: snapshot.record.sessionID, executing: false };
    // Even an idle successor can still be completing its boot sweep. Require
    // terminal interruption or bounded terminal-message settlement proof.
  }
  const bindingAtInterrupt = snapshot.binding;
  const recordAtInterrupt = snapshot.record;
  let settled = false;
  let result;
  try {
    result = nativeAPI(snapshot.binding, "session.interrupt", [...snapshot.args, "--param", "resume=false"]);
    if (typeof result.interrupted !== "boolean") throw new Error("native interrupt did not acknowledge exact worker cancellation");
    if (snapshot.incarnation === "successor" && !result.interrupted) {
      settled = await settledSuccessor(snapshot);
      if (!settled) {
        const warning = "successor reported idle interruption; no terminal cancellation or settlement of the old durable claim was proven and the turn may still resume";
        if (action !== "discard") throw new Error("REFUSED: " + warning + "; retry after recovery settles or use explicit --force discard");
        console.error("WARNING: forced discard without confirmed native cancellation: " + warning);
        return { sessionID: snapshot.record.sessionID, executing: null, cancellation: "unconfirmed" };
      }
    }
  }
  catch (error) {
    if (incarnationGone(snapshot.binding)) {
      const changed = workerSnapshot(file, worktree);
      const stopped = stoppedVerdict(changed);
      if (stopped) return stopped;
    }
    throw error;
  }
  for (let i = 0; i < 20; i++) {
    snapshot = workerSnapshot(file, worktree);
    const stopped = stoppedVerdict(snapshot);
    if (stopped) return stopped;
    if (snapshot.binding.servicePID !== bindingAtInterrupt.servicePID || snapshot.binding.serviceStart !== bindingAtInterrupt.serviceStart || snapshot.binding.hostBootID !== bindingAtInterrupt.hostBootID) throw new Error("REFUSED: native service restarted during cancellation; retry against its live successor");
    if (!snapshot.executing) {
      if (snapshot.incarnation === "successor") {
        // Record successor identity only after terminal cancellation and idle
        // settlement. Status discovery never silently rewrites worker authority.
        if (JSON.stringify(readPrivate(file)) !== JSON.stringify(recordAtInterrupt)) throw new Error("REFUSED: V2 worker binding changed during cancellation");
        writePrivate(file, bindingAtInterrupt);
      }
      return { sessionID: snapshot.record.sessionID, executing: false, interrupted: result.interrupted, cancellation: settled ? "settled" : "confirmed" };
    }
    await setTimeout(100);
  }
  throw new Error(`REFUSED: V2 worker ${snapshot.record.sessionID} still executing after native interrupt`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [action, file, worktree, generation] = process.argv.slice(2);
    if (action === "started") {
      const snapshot = workerSnapshot(file, worktree);
      if (!snapshot.recorded || snapshot.incarnation !== "original" || !Object.hasOwn(snapshot.record, "launchAfterMessageID")) throw new Error("secondmate launch has no current submission binding");
      if (!/^s[0-9]+\.[0-9]+\.[0-9]+$/.test(generation || "") || snapshot.record.spawnGeneration !== generation) throw new Error("secondmate submission belongs to an earlier spawn generation");
      if (snapshot.record.launchAfterMessageID !== null && typeof snapshot.record.launchAfterMessageID !== "string") throw new Error("invalid secondmate launch message binding");
      if (!snapshot.executing) {
        const messages = nativeAPI(snapshot.binding, "session.message.list", [...snapshot.args, "--param", "order=desc", "--param", "limit=1"]).data;
        const latest = messages?.[0];
        if (!Array.isArray(messages) || !latest?.id || latest.id === snapshot.record.launchAfterMessageID || !["assistant", "idle"].includes(latest.type)) throw new Error("secondmate launch has not started execution");
      }
      console.log("started");
    } else console.log(JSON.stringify(await reconcileWorker(action, file, worktree)));
  }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
