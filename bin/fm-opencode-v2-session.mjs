// Exact shared-worker execution reconciliation. CLI: status|interrupt|teardown|discard RECORD WORKTREE.
// session.get establishes placement/model; session.active is the native execution
// owner (session.get has no execution-status field on the qualified fork).
// Missing/unreadable/stale identity never becomes proof of stopped execution.
import { readPrivate, nativeAPI } from "./fm-opencode-v2-owner.mjs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout } from "node:timers/promises";

export function workerSnapshot(file, worktree) {
  const record = readPrivate(file);
  if (record.version !== 1 || !/^ses_[A-Za-z0-9_-]{1,160}$/.test(record.sessionID) || record.location?.directory !== resolve(worktree) || !record.model?.providerID || !record.model?.id) throw new Error("invalid recorded V2 worker binding");
  const args = ["--param", `sessionID=${record.sessionID}`, "--param", `location[directory]=${record.location.directory}`];
  if (nativeAPI(record, "server.info").pid !== record.servicePID) throw new Error("worker endpoint belongs to a different service");
  const info = nativeAPI(record, "session.get", args).data;
  if (info?.id !== record.sessionID || info.parentID || info.location?.directory !== record.location.directory || info.model?.providerID !== record.model.providerID || info.model?.id !== record.model.id || (info.model?.variant || "default") !== (record.model.variant || "default")) throw new Error(`recorded V2 worker session ${record.sessionID} changed identity/location/model`);
  const active = nativeAPI(record, "session.active").data;
  if (!active || typeof active !== "object" || Array.isArray(active) || Object.values(active).some(value => value?.type !== "running")) throw new Error("invalid native execution snapshot");
  return { record, args, executing: Object.hasOwn(active, record.sessionID) };
}

export async function reconcileWorker(action, file, worktree) {
  let snapshot = workerSnapshot(file, worktree);
  if (action === "status") return { sessionID: snapshot.record.sessionID, executing: snapshot.executing };
  if (action === "teardown") {
    if (snapshot.executing) throw new Error(`REFUSED: exact V2 worker ${snapshot.record.sessionID} is still executing; pane death is not stopped execution`);
    return { sessionID: snapshot.record.sessionID, executing: false };
  }
  if (!["interrupt", "discard"].includes(action)) throw new Error("invalid V2 worker reconciliation action");
  const result = nativeAPI(snapshot.record, "session.interrupt", [...snapshot.args, "--param", "resume=false"]);
  if (typeof result.interrupted !== "boolean") throw new Error("native interrupt did not acknowledge exact worker cancellation");
  for (let i = 0; i < 20; i++) {
    snapshot = workerSnapshot(file, worktree);
    if (!snapshot.executing) return { sessionID: snapshot.record.sessionID, executing: false, interrupted: result.interrupted };
    await setTimeout(100);
  }
  throw new Error(`REFUSED: V2 worker ${snapshot.record.sessionID} still executing after native interrupt`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await reconcileWorker(...process.argv.slice(2)))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
