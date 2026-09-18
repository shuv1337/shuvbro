import { createdOwnsThisLocation, eventSessionID, eventType, proveSessionOwnership } from "./fm-plugin-v2.js";

export function createSessionBinder(ctx) {
  const bound = new Set();
  const inflight = new Map();

  async function owns(sessionID) {
    if (!sessionID) return false;
    if (bound.size > 0 && !bound.has(sessionID)) return false;
    if (bound.has(sessionID)) return true;
    if (inflight.has(sessionID)) return inflight.get(sessionID);
    const pending = proveSessionOwnership(ctx, sessionID).then((ok) => {
      inflight.delete(sessionID);
      if (!ok) return false;
      if (bound.size > 0) return bound.has(sessionID);
      bound.add(sessionID);
      return true;
    });
    inflight.set(sessionID, pending);
    return pending;
  }

  async function observe(event) {
    const type = eventType(event);
    const sessionID = eventSessionID(event);
    if (!sessionID) return;
    if (type === "session.deleted") {
      bound.delete(sessionID);
      return;
    }
    if (type === "session.created" && createdOwnsThisLocation(event, ctx)) await owns(sessionID);
  }

  return { owns, observe, bound };
}
