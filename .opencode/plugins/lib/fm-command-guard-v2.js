import { effectivePaths, pluginRoot, runProcess } from "./fm-plugin-common.js";
import { commandFromPermission } from "./fm-plugin-v2.js";

export async function setupCommandGuardV2(ctx, { helper, fallbackReason }) {
  const root = await pluginRoot(ctx);
  if (!root) return;
  const paths = effectivePaths(root);
  const helperPath = `${root}/bin/${helper}`;
  const childEnv = {
    ...process.env,
    FM_ROOT_OVERRIDE: root,
    FM_HOME: paths.home,
    FM_STATE_OVERRIDE: paths.state,
    FM_CONFIG_OVERRIDE: paths.config,
  };

  async function denyReason(command) {
    if (!command || typeof command !== "string") return "";
    const result = await runProcess(helperPath, ["--command", command], { env: childEnv });
    if (result.code === 0) return "";
    if (result.code === 2) return result.stderr.trim() || fallbackReason;
    return result.stderr.trim() || "unable to evaluate the required shell guard";
  }

  if (!ctx.permission?.hook) return;
  await ctx.permission.hook("evaluate", async (event) => {
    const reason = await denyReason(commandFromPermission(event));
    if (!reason) return;
    event.effect = "deny";
    event.message = reason;
  });
}
