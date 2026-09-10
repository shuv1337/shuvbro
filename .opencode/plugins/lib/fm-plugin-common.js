import { spawn } from "node:child_process";
import { existsSync, readdirSync, realpathSync } from "node:fs";
import { resolve } from "node:path";

export function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

export function resolvePath(anchor) {
  if (!anchor) return "";
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export function runProcess(command, args, options = {}) {
  return new Promise((resolveResult) => {
    const proc = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    proc.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    proc.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    proc.on("error", (error) => {
      resolveResult({ code: 127, stdout, stderr: String(error?.message ?? error) });
    });
    proc.on("close", (code) => {
      resolveResult({ code: code ?? 0, stdout, stderr });
    });
  });
}

export async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export function effectivePaths(root) {
  const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot;
  const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
  const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
  return { root: fmRoot, home: fmHome, state, config };
}

export async function isPrimaryRoot(root, home) {
  if (!root) return false;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (existsSync(`${root}/.fm-secondmate-home`)) return false;
  if (home && home !== root && existsSync(`${home}/.fm-secondmate-home`)) return false;
  const gitDir = await runProcess("git", ["-C", root, "rev-parse", "--git-dir"]);
  const commonDir = await runProcess("git", ["-C", root, "rev-parse", "--git-common-dir"]);
  if (gitDir.code !== 0 || commonDir.code !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

export function shouldArm(paths) {
  if (existsSync(`${paths.state}/.afk`)) return false;
  if (existsSync(`${paths.config}/x-mode.env`)) return true;
  try {
    return readdirSync(paths.state).some((name) => name.endsWith(".meta"));
  } catch {
    return false;
  }
}

export function pluginDirectory(ctx) {
  return resolvePath(ctx?.location?.directory || ctx?.location?.project?.directory || "");
}

export function pluginRoot(ctx) {
  return resolvePath(
    ctx?.location?.project?.canonical || ctx?.location?.project?.directory || ctx?.location?.directory || "",
  );
}
