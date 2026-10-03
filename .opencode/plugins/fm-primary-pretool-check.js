import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";
import { definePlugin } from "./lib/fm-plugin-v2.js";

// PreToolUse seatbelt for OpenCode: the arm mechanism itself lives entirely in
// fm-primary-watch-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/fm-watch-arm.sh`
// wrong through its own bash tool - the anti-pattern bin/fm-arm-pretool-check.sh
// guards against (see that script's header and docs/arm-pretool-check.md).
// The V1 tool.execute.before path blocks by throwing (verified 2026-07-09
// against OpenCode 1.17.15). The V2 Effect entrypoint instead fails with a
// typed Tool.Error so the rejection is a normal tool failure, not a defect.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryPretoolCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${root}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};

export default definePlugin({
  id: "firstmate.v1.compat.pretool-check",
  setup() {},
  async server(input) {
    return FmPrimaryPretoolCheck(input);
  },
});
