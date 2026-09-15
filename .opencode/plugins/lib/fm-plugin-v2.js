import { pluginDirectory, resolvePath } from "./fm-plugin-common.js";

export function definePlugin(plugin) {
  return plugin;
}

export function eventType(event) {
  return event?.type || "";
}

export function eventData(event) {
  if (!event || typeof event !== "object") return {};
  if (event.data && typeof event.data === "object") return event.data;
  if (event.properties && typeof event.properties === "object") return event.properties;
  return event;
}

export function eventSessionID(event) {
  const data = eventData(event);
  return data.sessionID || data.info?.id || event?.sessionID || "";
}

export function eventParentID(event) {
  const data = eventData(event);
  return data.parentID || "";
}

export function eventLocationDirectory(event) {
  const data = eventData(event);
  return resolvePath(data.location?.directory || event?.location?.directory || "");
}

// shuvcode publishes no session.status or session.idle event to plugins; the
// runtime settles a turn with exactly one Execution terminal event, which its
// own projector maps to the session's idle time.
const IDLE_EVENT_TYPES = new Set([
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
]);

export function isIdleEvent(event) {
  return IDLE_EVENT_TYPES.has(eventType(event));
}

export function createTurnTracker() {
  const settled = new Set();
  return {
    turnEnded(event) {
      const sessionID = eventSessionID(event);
      if (!sessionID) return false;
      if (eventType(event) === "session.execution.started") {
        settled.delete(sessionID);
        return false;
      }
      if (!isIdleEvent(event)) return false;
      if (settled.has(sessionID)) return false;
      settled.add(sessionID);
      return true;
    },
  };
}

export function commandFromPermission(event) {
  if (!event || typeof event !== "object") return "";
  if (typeof event.metadata?.command === "string") return event.metadata.command;
  const action = event.action;
  if (action !== "shell" && action !== "bash") return "";
  const resources = event.resources;
  if (!Array.isArray(resources)) return "";
  const first = resources.find((item) => typeof item === "string" && item);
  return first || "";
}

export function sameDirectory(left, right) {
  const a = resolvePath(left);
  const b = resolvePath(right);
  return Boolean(a) && a === b;
}

export function createdOwnsThisLocation(event, ctx) {
  if (eventParentID(event)) return false;
  const sessionDir = eventLocationDirectory(event);
  const pluginDir = pluginDirectory(ctx);
  if (!sessionDir || !pluginDir) return false;
  return sessionDir === pluginDir;
}

export async function proveSessionOwnership(ctx, sessionID) {
  if (!sessionID || !ctx?.session?.get) return false;
  try {
    const result = await ctx.session.get({ sessionID });
    const info = result?.data ?? result;
    if (!info) return false;
    if (info.parentID) return false;
    const sessionDir = resolvePath(info.location?.directory || "");
    const pluginDir = pluginDirectory(ctx);
    if (!sessionDir || !pluginDir) return false;
    return sessionDir === pluginDir;
  } catch {
    return false;
  }
}

export async function promptQueued(ctx, sessionID, text) {
  if (!ctx?.session?.prompt) {
    throw new Error("session.prompt is unavailable");
  }
  return ctx.session.prompt({
    sessionID,
    text,
    delivery: "queue",
  });
}

export function subscribeEvents(ctx, signal) {
  if (!ctx?.event?.subscribe) {
    return {
      async *[Symbol.asyncIterator]() {},
    };
  }
  return ctx.event.subscribe({ signal });
}
