import { effectivePaths, pluginRoot, runProcess } from "./fm-plugin-common.js";
import { commandFromPermission } from "./fm-plugin-v2.js";

// Shuvcode resolves these runtime packages for local plugins. Keep the imports
// optional so the credential-free Node unit harness can still inspect the
// dual V1/V2 export shape without installing Shuvcode's internal packages.
let EffectRuntime;
let ToolRuntime;
try {
  [{ Effect: EffectRuntime }, { Tool: ToolRuntime }] = await Promise.all([
    import("effect"),
    import("@opencode/schema/tool"),
  ]);
} catch {
  // The Effect entrypoint below is never invoked by the standalone unit loader.
}

export function commandFromTool(event) {
  if (!event || typeof event !== "object") return "";
  if (event.tool !== "shell" && event.tool !== "bash") return "";
  return typeof event.input?.command === "string" ? event.input.command : "";
}

function commandGuard(ctx, { helper, fallbackReason }) {
  return async function build() {
    const root = await pluginRoot(ctx);
    if (!root) return { denyReason: async () => "" };
    const paths = effectivePaths(root);
    const helperPath = `${root}/bin/${helper}`;
    const childEnv = {
      ...process.env,
      FM_ROOT_OVERRIDE: root,
      FM_HOME: paths.home,
      FM_STATE_OVERRIDE: paths.state,
      FM_CONFIG_OVERRIDE: paths.config,
    };

    return {
      async denyReason(command) {
        if (!command || typeof command !== "string") return "";
        const result = await runProcess(helperPath, ["--command", command], { env: childEnv });
        if (result.code === 0) return "";
        if (result.code === 2) return result.stderr.trim() || fallbackReason;
        return result.stderr.trim() || "unable to evaluate the required shell guard";
      },
    };
  };
}

export function setupCommandGuardEffectV2(ctx, options) {
  if (!EffectRuntime || !ToolRuntime) {
    throw new Error("Shuvcode Effect plugin runtime is unavailable");
  }
  const build = commandGuard(ctx, options);
  return EffectRuntime.gen(function* () {
    const guard = yield* EffectRuntime.promise(build);
    yield* ctx.tool.hook("execute.before", (event) => {
      const command = commandFromTool(event);
      if (!command) return EffectRuntime.void;
      return EffectRuntime.tryPromise({
        try: () => guard.denyReason(command),
        catch: (cause) => new ToolRuntime.Error({
          message: "unable to evaluate the required shell guard",
          error: cause,
        }),
      }).pipe(
        EffectRuntime.flatMap((reason) => reason
          ? EffectRuntime.fail(new ToolRuntime.Error({ message: reason }))
          : EffectRuntime.void),
      );
    });
  });
}

export async function setupCommandGuardV2(ctx, { helper, fallbackReason }) {
  const guard = await commandGuard(ctx, { helper, fallbackReason })();

  if (!ctx.permission?.hook) return;
  await ctx.permission.hook("evaluate", async (event) => {
    const reason = await guard.denyReason(commandFromPermission(event));
    if (!reason) return;
    event.effect = "deny";
    event.message = reason;
  });
}
