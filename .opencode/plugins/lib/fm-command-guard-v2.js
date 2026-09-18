import { effectivePaths, pluginRoot, runProcess } from "./fm-plugin-common.js";

// Shuvcode resolves a project plugin's bare imports natively and shares none
// of its own modules, so the Effect runtime is the pinned dependency of
// .opencode/plugins/package.json (install: npm ci --prefix .opencode/plugins).
// The import stays dynamic because V1 opencode and the Node unit harness load
// this file without that install; the Effect entrypoint reports the retained
// failure instead of registering nothing silently.
const runtime = await import("effect").then(
  (module) => ({ module }),
  (error) => ({ error }),
);

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

export function setupCommandGuardEffectV2(ctx, options, effectModule = runtime.module) {
  if (!effectModule) {
    throw new Error(
      "the shell guard cannot load the effect runtime; run: npm ci --prefix .opencode/plugins",
      { cause: runtime.error },
    );
  }
  const { Data, Effect } = effectModule;
  // Shuvcode matches a rejected tool call on the Tool.Error tag, not on its
  // own class, which a project plugin cannot import.
  class ToolError extends Data.TaggedError("Tool.Error") {}
  const build = commandGuard(ctx, options);
  return Effect.gen(function* () {
    const guard = yield* Effect.promise(build);
    yield* ctx.tool.hook("execute.before", (event) => {
      const command = commandFromTool(event);
      if (!command) return Effect.void;
      return Effect.tryPromise({
        try: () => guard.denyReason(command),
        catch: (cause) => new ToolError({
          message: "unable to evaluate the required shell guard",
          error: cause,
        }),
      }).pipe(
        Effect.flatMap((reason) => reason
          ? Effect.fail(new ToolError({ message: reason }))
          : Effect.void),
      );
    });
  });
}
