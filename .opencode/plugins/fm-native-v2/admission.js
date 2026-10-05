import { existsSync, readFileSync, readdirSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { readPrivate, writePrivate } from "../../../bin/fm-opencode-v2-owner.mjs";

// Admission journal is adapter transport, not wake-row ownership. Only the
// canonical drain/ack owner consumes queue rows. IDs/text survive replacement
// successors, owner reload and unknown native prompt acknowledgement.
// One outstanding steer doorbell at a time: native admission is not handling.
// Canonical rows or the current recovery episode retain the doorbell slot.
export function createAdmissionJournal(paths, sessionID, admit, report = console.error, options = {}) {
  const dir = join(paths.state, ".opencode-v2-admissions", createHash("sha256").update(sessionID).digest("hex"));
  const inflight = new Map(), retries = new Map();
  let wakeSlot = "";
  const allowed = () => !options.signal?.aborted && (!options.valid || options.valid());
  function validate(value) {
    if (value.version !== 1 || value.sessionID !== sessionID || !/^msg_[a-f0-9]{64}$/.test(value.id) || typeof value.kind !== "string" || typeof value.text !== "string" || value.text.length > 12000 || !Array.isArray(value.rows) || value.rows.some(row => typeof row !== "string" || !/^[0-9]+\t[0-9]+$/.test(row)) || !["prepared", "confirmed", "admitted", "acknowledged"].includes(value.phase)) throw new Error("invalid V2 admission record");
    return value;
  }
  // The canonical drain advances this sequence on every main presentation and
  // names the highest row sequence it presented. Missing means no drain yet;
  // malformed state cannot prove a later drain or a presented row.
  function drainReceipt() {
    try {
      const match = readFileSync(join(paths.state, ".wake-drain-presented"), "utf8").match(/^([0-9]{1,15})\t[A-Za-z0-9._-]{0,200}(?:\t([0-9]{1,15}))?\n?$/);
      return match ? { sequence: Number(match[1]), presented: match[2] === undefined ? null : Number(match[2]) } : { sequence: null, presented: null };
    } catch (error) { return { sequence: error.code === "ENOENT" ? 0 : null, presented: null }; }
  }
  function drainSequence() { return drainReceipt().sequence; }
  function save(value) { writePrivate(join(dir, value.id + ".json"), validate(value)); return value; }
  function prepare(text, kind = "wake", context = {}) {
    let logical = kind;
    let identities = [];
    let covered = false;
    if (kind === "wake") {
      let queue;
      try { queue = readFileSync(join(paths.state, ".wake-queue"), "utf8"); }
      catch (error) { if (error.code !== "ENOENT") throw error; queue = ""; }
      identities = queue.trim().split("\n").filter(Boolean).map(line => line.split("\t").slice(0, 2).join("\t"));
      if (!identities.length) {
        const generation = context.recovery?.generation;
        // A canonical handling generation is the identity for a no-row
        // rearm-resurface presentation. No timestamp/random synthetic wake.
        if (typeof generation !== "string" || !/^[A-Za-z0-9._-]{1,200}$/.test(generation)) throw new Error("actionable close has neither durable wake rows nor recovery generation");
        logical += ":recovery:" + generation;
      } else {
        // Rows a drain already presented are covered by it; a later wake is
        // the doorbell for the rows that arrived after that drain.
        const { presented } = drainReceipt();
        const later = Number.isInteger(presented) ? identities.filter(row => Number(row.split("\t")[1]) > presented) : [];
        if (later.length) identities = later;
        else covered = Number.isInteger(presented);
        const prior = pending().find(value => value.rows.some(row => identities.includes(row)));
        if (prior) return prior;
        logical += ":" + identities.join("\n");
      }
    }
    const id = "msg_" + createHash("sha256").update(sessionID + "\0" + logical).digest("hex");
    try { return validate(readPrivate(join(dir, id + ".json"))); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    return save({ version: 1, sessionID, id, kind, rows: identities, text, context, phase: covered ? "acknowledged" : "prepared", drain: drainSequence() });
  }
  function drainedSince(value) {
    const drained = drainSequence();
    return Number.isInteger(value.drain) && Number.isInteger(drained) && drained > value.drain;
  }
  function acknowledged(value) {
    // Callers can retain their pre-admission snapshot across a native receipt
    // or reconciliation. Retirement follows the durable phase, not that copy.
    value = validate(readPrivate(join(dir, value.id + ".json")));
    if (value.phase === "acknowledged") return true;
    // A doorbell is handled once a drain is recorded after its admission, even
    // if rows remain queued; rows arriving after that drain need their own.
    if (value.kind === "wake" && value.phase === "admitted" && drainedSince(value)) {
      save({ ...value, phase: "acknowledged" });
      return true;
    }
    // An unadmitted row wake whose every row a later drain presented is
    // covered by that drain and retires without its own doorbell.
    if (value.kind === "wake" && value.rows.length && drainedSince(value)) {
      const { presented } = drainReceipt();
      if (Number.isInteger(presented) && value.rows.every(row => Number(row.split("\t")[1]) <= presented)) {
        save({ ...value, phase: "acknowledged" });
        return true;
      }
    }
    if (!value.rows.length) {
      // Recovery has no row identities. A drain presented after preparation
      // also covers a confirmed obligation. Otherwise exact-generation ack
      // retires a confirmed obligation, and an admitted doorbell stays
      // outstanding until any generation is acked. Missing or malformed state
      // retains it.
      const generation = value.context?.recovery?.generation;
      if (value.kind !== "wake" || !["confirmed", "admitted"].includes(value.phase) || typeof generation !== "string" || !/^[A-Za-z0-9._-]{1,200}$/.test(generation)) return false;
      if (drainedSince(value)) {
        save({ ...value, phase: "acknowledged" });
        return true;
      }
      let marker;
      try { marker = readFileSync(join(paths.state, ".watcher-down"), "utf8").trim(); } catch { return false; }
      const episode = marker.match(/^acked:(?:handling|downtime):([A-Za-z0-9._-]{1,200})$/);
      if (!episode || value.phase === "confirmed" && episode[1] !== generation) return false;
      save({ ...value, phase: "acknowledged" });
      return true;
    }
    // Reading the canonical queue never consumes it. Once its sole ack owner
    // removed every captured row, this transport obligation is obsolete, not
    // "admitted". Missing/unreadable queue does not establish acknowledgement.
    let queue;
    try { queue = readFileSync(join(paths.state, ".wake-queue"), "utf8"); } catch { return false; }
    const current = new Set(queue.trim().split("\n").filter(Boolean).map(line => line.split("\t").slice(0, 2).join("\t")));
    if (value.rows.some(row => current.has(row))) return false;
    if (value.phase !== "acknowledged") save({ ...value, phase: "acknowledged" });
    return true;
  }
  function outstandingDoorbells(exceptId) {
    if (!existsSync(dir)) return [];
    const result = [];
    for (const name of readdirSync(dir).filter(name => /^msg_[a-f0-9]{64}\.json$/.test(name))) {
      const value = validate(readPrivate(join(dir, name)));
      // A doorbell admitted by an older claim cannot hold this owner's slot.
      if (value.id === exceptId || value.kind !== "wake" || value.phase !== "admitted" || value.claim !== options.claim) continue;
      if (!acknowledged(value)) result.push(value);
    }
    return result;
  }
  function parkedBehindDoorbell(value) {
    return value.kind === "wake" && !["admitted", "acknowledged"].includes(value.phase) && ((wakeSlot && wakeSlot !== value.id) || outstandingDoorbells(value.id).length > 0);
  }
  // Parking behind a doorbell the lead has not drained yet is coalescing. It
  // is stuck only if a drain is recorded that cannot be proven to precede the
  // blocking admission, since that drain should have retired the blocker.
  function stalled(value) {
    if (!parkedBehindDoorbell(value)) return false;
    const drained = drainSequence();
    if (drained === 0) return false;
    return outstandingDoorbells(value.id).some(blocker => !Number.isInteger(blocker.drain) || !Number.isInteger(drained) || drained > blocker.drain);
  }
  async function attemptDelivery(value) {
    validate(value);
    if (["admitted", "acknowledged"].includes(value.phase) || acknowledged(value)) return true;
    if (value.kind === "wake" && value.phase !== "confirmed") throw new Error("V2 wake admission requires successor confirmation first");
    if (parkedBehindDoorbell(value)) return false;
    const retry = retries.get(value.id);
    if (retry && Date.now() < retry.after) return false;
    if (value.kind === "wake") wakeSlot = value.id;
    try {
      for (let attempt = 0; attempt < 5; attempt++) {
        if (acknowledged(value)) { retries.delete(value.id); return true; }
        try {
          if (!allowed()) throw new Error("V2 admission cancelled after ownership loss or retirement");
          // A steer reaches a busy lead at its next step boundary. The slot
          // remains occupied until canonical handling, not the native receipt.
          const drain = drainSequence();
          const result = await admit({ sessionID, id: value.id, text: value.text, delivery: "steer" });
          if (result?.id !== value.id) throw new Error("native admission did not acknowledge the exact message ID");
          save({ ...value, phase: "admitted", claim: options.claim, drain });
          retries.delete(value.id);
          return true;
        } catch (error) {
          if (attempt === 4) {
            const failures = (retry?.failures || 0) + 1;
            retries.set(value.id, { failures, after: Date.now() + Math.min(30000, 2000 * 2 ** Math.min(failures, 4)) });
            if (failures === 1) report("V2 steer admission remains pending: " + error.message);
            throw error;
          }
          await new Promise(resolve => setTimeout(resolve, 100 * 2 ** attempt));
        }
      }
    } finally {
      if (wakeSlot === value.id) wakeSlot = "";
    }
  }
  function deliver(value) {
    if (inflight.has(value.id)) return inflight.get(value.id);
    value = validate(readPrivate(join(dir, value.id + ".json")));
    const promise = attemptDelivery(value).finally(() => inflight.delete(value.id));
    inflight.set(value.id, promise);
    return promise;
  }
  function pending() {
    if (!existsSync(dir)) return [];
    const result = [];
    for (const name of readdirSync(dir).filter(name => /^msg_[a-f0-9]{64}\.json$/.test(name))) {
      const path = join(dir, name), value = validate(readPrivate(path));
      // Keep claim startup deduplication and every unadmitted obligation. Old
      // canonically retired wakes can expire; outstanding recoveries cannot.
      const old = Date.now() - statSync(path).mtimeMs > 7 * 24 * 60 * 60 * 1000;
      const acked = acknowledged(value);
      if (value.kind === "wake" && acked && old) { unlinkSync(path); continue; }
      if (value.kind.startsWith("failure:") && old && (value.phase === "admitted" || options.failureClaim && !value.kind.startsWith("failure:" + options.failureClaim + ":"))) { unlinkSync(path); retries.delete(value.id); continue; }
      if (!["admitted", "acknowledged"].includes(value.phase) && !acked) result.push(value);
    }
    return result;
  }
  return {
    prepare,
    parked: parkedBehindDoorbell,
    stalled,
    confirm: (value, recovery) => {
      const phase = ["admitted", "acknowledged"].includes(value.phase) ? value.phase : "confirmed";
      if (value.phase === phase && JSON.stringify(value.context?.confirmedRecovery) === JSON.stringify(recovery || null)) return value;
      return save({ ...value, context: { ...value.context, confirmedRecovery: recovery || null }, phase });
    },
    deliver,
    pending, acknowledged,
  };
}
