// Exact shared-worker execution reconciliation. CLI: status|interrupt|teardown|discard RECORD WORKTREE.
// session.get establishes placement/model; session.active is the native execution
// owner (session.get has no execution-status field on the qualified fork).
// The sidecar is published before prompt admission: absent means unrecorded.
// A provably gone process incarnation cannot still own native execution.
// Malformed records and ambiguous/unverifiable live processes still refuse.
import { readPrivate, nativeAPI, identity, serviceURL } from "./fm-opencode-v2-owner.mjs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout } from "node:timers/promises";

function incarnationGone(record) {
  try {
    const current = identity(record.servicePID);
    return current.start !== record.serviceStart || current.boot !== record.hostBootID;
  } catch (error) {
    if (error.code === "ESRCH" || error.code === "ENOENT" && [`/proc/${record.servicePID}/stat`, `/proc/${record.servicePID}`].includes(error.path)) return true;
    throw error; // permission, unsupported-host, foreign-user or unreadable proof
  }
}

export function workerSnapshot(file, worktree) {
  let record;
  try { record = readPrivate(file); }
  catch (error) { if (error.code !== "ENOENT") throw error; return { recorded: false, executing: false }; }
  if (
    record.version !== 1 || !/^ses_[A-Za-z0-9_-]{1,160}$/.test(record.sessionID) || record.location?.directory !== resolve(worktree) ||
    typeof record.model?.providerID !== "string" || !record.model.providerID || typeof record.model?.id !== "string" || !record.model.id ||
    record.model.variant !== undefined && (typeof record.model.variant !== "string" || !record.model.variant) ||
    !Number.isSafeInteger(record.servicePID) || record.servicePID < 2 || typeof record.serviceStart !== "string" || !/^(0|[1-9][0-9]*)$/.test(record.serviceStart) ||
    typeof record.hostBootID !== "string" || !/^[a-f0-9-]{36}$/.test(record.hostBootID) || serviceURL(record.serviceURL) !== record.serviceURL
  ) throw new Error("invalid recorded V2 worker binding");
  const gone = { record, recorded: true, executing: false, incarnation: "gone" };
  if (incarnationGone(record)) return gone;
  const args = ["--param", `sessionID=${record.sessionID}`, "--param", `location[directory]=${record.location.directory}`];
  try {
    if (nativeAPI(record, "server.info").pid !== record.servicePID) throw new Error("worker endpoint belongs to a different service");
    const info = nativeAPI(record, "session.get", args).data;
    if (info?.id !== record.sessionID || info.parentID || info.location?.directory !== record.location.directory || info.model?.providerID !== record.model.providerID || info.model?.id !== record.model.id || (info.model?.variant || "default") !== (record.model.variant || "default")) throw new Error(`recorded V2 worker session ${record.sessionID} changed identity/location/model`);
    const active = nativeAPI(record, "session.active").data;
    if (!active || typeof active !== "object" || Array.isArray(active) || Object.values(active).some(value => value?.type !== "running")) throw new Error("invalid native execution snapshot");
    return { record, recorded: true, args, executing: Object.hasOwn(active, record.sessionID) };
  } catch (error) {
    // A stop/restart can race the initial proof or any API request. Recheck
    // process birth, never interpret an API/registration failure alone as idle.
    if (incarnationGone(record)) return gone;
    throw error;
  }
}

export async function reconcileWorker(action, file, worktree) {
  if (!["status", "teardown", "interrupt", "discard"].includes(action)) throw new Error("invalid V2 worker reconciliation action");
  let snapshot = workerSnapshot(file, worktree);
  const stoppedVerdict = value => {
    if (value.recorded === false) {
      console.error("V2 task has no recorded native session; no prompt was admitted.");
      return { executing: false, recorded: false };
    }
    if (value.incarnation === "gone") return { sessionID: value.record.sessionID, executing: false, recorded: true, incarnation: "gone" };
  };
  const stopped = stoppedVerdict(snapshot);
  if (stopped) return stopped;
  if (action === "status") return { sessionID: snapshot.record.sessionID, executing: snapshot.executing };
  if (action === "teardown") {
    if (snapshot.executing) throw new Error(`REFUSED: exact V2 worker ${snapshot.record.sessionID} is still executing; pane death is not stopped execution`);
    return { sessionID: snapshot.record.sessionID, executing: false };
  }
  let result;
  try {
    result = nativeAPI(snapshot.record, "session.interrupt", [...snapshot.args, "--param", "resume=false"]);
    if (typeof result.interrupted !== "boolean") throw new Error("native interrupt did not acknowledge exact worker cancellation");
  }
  catch (error) {
    if (incarnationGone(snapshot.record)) return { sessionID: snapshot.record.sessionID, executing: false, recorded: true, incarnation: "gone" };
    throw error;
  }
  for (let i = 0; i < 20; i++) {
    snapshot = workerSnapshot(file, worktree);
    const stopped = stoppedVerdict(snapshot);
    if (stopped) return stopped;
    if (!snapshot.executing) return { sessionID: snapshot.record.sessionID, executing: false, interrupted: result.interrupted };
    await setTimeout(100);
  }
  throw new Error(`REFUSED: V2 worker ${snapshot.record.sessionID} still executing after native interrupt`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await reconcileWorker(...process.argv.slice(2)))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
