import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { readPrivate, writePrivate } from "../../../bin/fm-opencode-v2-owner.mjs";

// Admission journal is adapter transport, not wake-row ownership. Only the
// canonical drain/ack owner consumes queue rows. IDs/text survive replacement
// successors, owner reload and unknown native prompt acknowledgement.
export function createAdmissionJournal(paths, sessionID, admit, report = console.error, options = {}) {
  const dir = join(paths.state, ".opencode-v2-admissions", createHash("sha256").update(sessionID).digest("hex"));
  const inflight = new Map(), retries = new Map();
  const allowed = () => !options.signal?.aborted && (!options.valid || options.valid());
  function validate(value) {
    if (value.version !== 1 || value.sessionID !== sessionID || !/^msg_[a-f0-9]{64}$/.test(value.id) || typeof value.kind !== "string" || typeof value.text !== "string" || value.text.length > 12000 || !Array.isArray(value.rows) || value.rows.some(row => typeof row !== "string" || !/^[0-9]+\t[0-9]+$/.test(row)) || !["prepared", "confirmed", "admitted", "acknowledged"].includes(value.phase)) throw new Error("invalid V2 admission record");
    return value;
  }
  function save(value) { writePrivate(join(dir, value.id + ".json"), validate(value)); return value; }
  function prepare(text, kind = "wake", context = {}) {
    let logical = kind;
    let identities = [];
    if (kind === "wake") {
      const queue = readFileSync(join(paths.state, ".wake-queue"), "utf8");
      identities = queue.trim().split("\n").filter(Boolean).map(line => line.split("\t").slice(0, 2).join("\t"));
      if (!identities.length) throw new Error("actionable close has no durable wake rows");
      const prior = pending().find(value => value.rows.some(row => identities.includes(row)));
      if (prior) return prior;
      logical += ":" + identities.join("\n");
    }
    const id = "msg_" + createHash("sha256").update(sessionID + "\0" + logical).digest("hex");
    try { return validate(readPrivate(join(dir, id + ".json"))); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    return save({ version: 1, sessionID, id, kind, rows: identities, text, context, phase: "prepared" });
  }
  function acknowledged(value) {
    if (!value.rows.length) return false;
    // Reading the canonical queue never consumes it. Once its sole ack owner
    // removed every captured row, this transport obligation is obsolete, not
    // "admitted". Missing/unreadable queue does not establish acknowledgement.
    let queue;
    try { queue = readFileSync(join(paths.state, ".wake-queue"), "utf8"); } catch { return false; }
    const current = new Set(queue.trim().split("\n").filter(Boolean).map(line => line.split("\t").slice(0, 2).join("\t")));
    if (value.rows.some(row => current.has(row))) return false;
    save({ ...value, phase: "acknowledged" });
    return true;
  }
  async function attemptDelivery(value) {
    validate(value);
    if (["admitted", "acknowledged"].includes(value.phase) || acknowledged(value)) return;
    const retry = retries.get(value.id);
    if (retry && Date.now() < retry.after) return;
    for (let attempt = 0; attempt < 5; attempt++) {
      if (!allowed()) throw new Error("V2 admission cancelled after ownership loss or retirement");
      try {
        const result = await admit({ sessionID, id: value.id, text: value.text, delivery: "queue" });
        if (result?.id !== value.id) throw new Error("native admission did not acknowledge the exact message ID");
        save({ ...value, phase: "admitted" });
        retries.delete(value.id);
        return;
      } catch (error) {
        if (attempt === 4) {
          const failures = (retry?.failures || 0) + 1;
          retries.set(value.id, { failures, after: Date.now() + Math.min(30000, 2000 * 2 ** Math.min(failures, 4)) });
          if (failures === 1) report("V2 queued admission remains pending: " + error.message);
          throw error;
        }
        await new Promise(resolve => setTimeout(resolve, 100 * 2 ** attempt));
      }
    }
  }
  function deliver(value) {
    if (inflight.has(value.id)) return inflight.get(value.id);
    const promise = attemptDelivery(value).finally(() => inflight.delete(value.id));
    inflight.set(value.id, promise);
    return promise;
  }
  function pending() {
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter(name => /^msg_[a-f0-9]{64}\.json$/.test(name)).map(name => validate(readPrivate(join(dir, name)))).filter(value => !["admitted", "acknowledged"].includes(value.phase) && !acknowledged(value));
  }
  return {
    prepare,
    confirm: (value, recovery) => save({ ...value, context: { ...value.context, confirmedRecovery: recovery || null }, phase: value.phase === "admitted" ? "admitted" : "confirmed" }),
    deliver,
    pending, acknowledged,
  };
}
