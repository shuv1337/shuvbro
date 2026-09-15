import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { effectivePaths, pluginRoot } from "./lib/fm-plugin-common.js";
import { watchOwnerFor } from "./lib/fm-watch-arm-v2.js";
import { createSessionBinder } from "./lib/fm-session-bind-v2.js";
import {
  createTurnTracker,
  definePlugin,
  eventSessionID,
  promptQueued,
  subscribeEvents,
} from "./lib/fm-plugin-v2.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID, client)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};

const turnendSkip = new Map();

function skipKey(home, sessionID) {
  return `${home}\0${sessionID}`;
}

async function setupTurnendGuardV2(ctx) {
  const root = await pluginRoot(ctx);
  if (!root) return;
  const paths = effectivePaths(root);
  const binder = createSessionBinder(ctx);
  const turns = createTurnTracker();
  const abort = new AbortController();

  void (async () => {
    try {
      for await (const event of subscribeEvents(ctx, abort.signal)) {
        binder.observe(event);
        if (!turns.turnEnded(event)) continue;
        const sessionID = eventSessionID(event);
        if (!(await binder.owns(sessionID))) continue;
        const key = skipKey(paths.home, sessionID);
        if (turnendSkip.get(key)) {
          turnendSkip.delete(key);
          continue;
        }
        const coordinator = watchOwnerFor(paths.home);
        if (coordinator?.ensureArmed) {
          const status = await coordinator.ensureArmed(sessionID);
          if (status === "armed" || status === "wake" || status === "failed") continue;
        }
        const result = await runGuard(root);
        if (result.code !== 2) continue;
        try {
          const text = await encodeFirstmateOperationalInput(
            root,
            "turn-end-guard",
            "TURN WOULD END BLIND - supervision is off. " +
              "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
              result.stderr,
          );
          await promptQueued(ctx, sessionID, text);
          turnendSkip.set(key, true);
        } catch {
          turnendSkip.delete(key);
        }
      }
    } catch {
      if (abort.signal.aborted) return;
    }
  })();

  return () => {
    abort.abort();
    for (const key of [...turnendSkip.keys()]) {
      if (key.startsWith(`${paths.home}\0`)) turnendSkip.delete(key);
    }
  };
}

export default definePlugin({
  id: "fm-primary-turnend-guard",
  setup: setupTurnendGuardV2,
  async server(input) {
    return FmPrimaryTurnendGuard(input);
  },
});
