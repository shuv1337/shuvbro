import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { pluginRoot, runProcess as runProcessStrict } from "./lib/fm-plugin-common.js";
import { createSessionBinder } from "./lib/fm-session-bind-v2.js";
import {
  definePlugin,
  eventSessionID,
  eventType,
  isIdleEvent,
  promptQueued,
  subscribeEvents,
} from "./lib/fm-plugin-v2.js";

const handledSessions = new Set();

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export const FmPrimarySessionstartNudge = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.properties?.info?.id ?? event.properties?.sessionID;
      if (!sessionID || handledSessions.has(sessionID) || !root) return;
      handledSessions.add(sessionID);

      const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      try {
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text: nudge }],
          },
        });
      } catch {
      }
    },
  };
};

const nudgedSessions = new Set();

function nudgeKey(root, sessionID) {
  return `${root}\0${sessionID}`;
}

async function setupSessionstartNudgeV2(ctx) {
  const root = pluginRoot(ctx);
  if (!root) return;
  const binder = createSessionBinder(ctx);
  const abort = new AbortController();

  async function deliverNudge(sessionID) {
    const key = nudgeKey(root, sessionID);
    if (!sessionID || nudgedSessions.has(key)) return;
    if (!(await binder.owns(sessionID))) return;
    const result = await runProcessStrict(`${root}/bin/fm-sessionstart-nudge.sh`, []);
    const nudge = result.code === 0 ? result.stdout.trim() : "";
    if (!nudge) return;
    try {
      await promptQueued(ctx, sessionID, nudge);
      nudgedSessions.add(key);
    } catch {
      nudgedSessions.delete(key);
    }
  }

  void (async () => {
    try {
      for await (const event of subscribeEvents(ctx, abort.signal)) {
        binder.observe(event);
        const sessionID = eventSessionID(event);
        if (eventType(event) === "session.created" || isIdleEvent(event)) {
          await deliverNudge(sessionID);
        }
      }
    } catch {
      if (abort.signal.aborted) return;
    }
  })();

  return () => {
    abort.abort();
    for (const key of [...nudgedSessions]) {
      if (key.startsWith(`${root}\0`)) nudgedSessions.delete(key);
    }
  };
}

export default {
  ...definePlugin({
    id: "fm-primary-sessionstart-nudge",
    setup: setupSessionstartNudgeV2,
  }),
  async server(input) {
    return FmPrimarySessionstartNudge(input);
  },
};
