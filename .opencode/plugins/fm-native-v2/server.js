import { readRegistration, registrationPresence, live, canonical, markerKey } from "../../../bin/fm-opencode-v2-owner.mjs";
import { runProcess } from "../lib/fm-plugin-common.js";
import { commandFromTool } from "../lib/fm-command-guard-v2.js";
import { bindingRPC } from "./rpc.js";

const runtime = await import("effect").catch(() => null);

// Exported for behavioral harnesses. Native session evidence, not plugin
// location/environment, decides whether a registered root needs protection.
export async function guardScope(sessionAPI, sessionID) {
  const result = await sessionAPI.get({ sessionID });
  const info = result?.data ?? result;
  if (!info || info.id !== sessionID) throw new Error("cannot inspect exact shell session");
  if (info.parentID) return { registered: false };
  const marker = info.metadata?.[markerKey];
  let record;
  try { record = readRegistration(sessionID); }
  catch (error) {
    let exactRecord = false;
    try { exactRecord = registrationPresence(sessionID); } catch { /* infrastructure is not session authority */ }
    if (exactRecord || marker?.sessionID === sessionID) return { registered: true, error: "exact lead registration is missing or unsafe; explicitly rebind before continuing" };
    return { registered: false };
  }
  try {
    if (marker?.version !== 1 || marker.sessionID !== sessionID || marker.claimID !== record.claimID || info.location?.directory !== record.root) throw new Error("exact lead marker disagrees");
    live(record, process.pid);
    canonical(record, false);
    return { registered: true, record };
  } catch { return { registered: true, error: "exact lead owner or execution service is stale; explicitly rebind before continuing" }; }
}

export async function bindingStatus(sessionAPI, { sessionID, claimID }) {
  if (!/^ses_[A-Za-z0-9_-]{1,160}$/.test(sessionID) || !/^[a-f0-9]{48}$/.test(claimID)) return { status: "unknown" };
  try {
    const scope = await guardScope(sessionAPI, sessionID);
    if (!scope.registered) return { status: "unknown" };
    return { status: !scope.error && scope.record.claimID === claimID ? "valid" : "stale" };
  } catch { return { status: "stale" }; }
}

export async function denyReason(sessionAPI, event) {
  const command = commandFromTool(event);
  if (!command) return "";
  const scope = await guardScope(sessionAPI, event.sessionID);
  if (!scope.registered) return "";
  if (scope.error) return scope.error;
  const { root, home, state, config } = scope.record;
  for (const [helper, args] of [
    ["fm-cd-command-policy.mjs", ["--command", command]],
    ["fm-arm-command-policy.mjs", ["--command", command, "--root", root, "--home", home]],
  ]) {
    // The V1 transport wrappers intentionally have fail-open paths and linked
    // copy exclusions. Native exact-lead scope is already proven here; invoke
    // the SAME classifiers directly and require a well-formed verdict.
    const result = await runProcess("node", [`${root}/bin/${helper}`, ...args], {
      cwd: root, timeout: 10000,
      env: { ...process.env, FM_ROOT_OVERRIDE: root, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_CONFIG_OVERRIDE: config, OPENCODE_SESSION_ID: event.sessionID },
    });
    if (result.code !== 0) return result.stderr.trim() || "required firstmate shell guard could not evaluate this command";
    const verdict = result.stdout.trim();
    if (verdict === "allow") continue;
    const denied = verdict.match(/^deny\t([^\t\r\n]+)\t([^\r\n]+)$/);
    if (!denied) return "required firstmate shell classifier returned an invalid verdict";
    return `[${denied[1]}] ${denied[2]}`;
  }
  return "";
}

function effect(ctx) {
  const { Data, Effect } = runtime;
  class ToolError extends Data.TaggedError("Tool.Error") {}
  const api = { get: input => Effect.runPromise(ctx.session.get(input)) };
  return Effect.gen(function* () {
    yield* ctx.rpc.register(bindingRPC, {
      bindingStatus: input => Effect.promise(() => bindingStatus(api, input)),
    });
    yield* ctx.tool.hook("execute.before", event => Effect.tryPromise({
      try: () => denyReason(api, event),
      catch: cause => new ToolError({ message: "unable to evaluate exact-session firstmate guard", error: cause }),
    }).pipe(Effect.flatMap(reason => reason ? Effect.fail(new ToolError({ message: reason })) : Effect.void)));
  });
}

async function missingRuntime(ctx) {
  await ctx.rpc.register(bindingRPC, { bindingStatus: input => bindingStatus(ctx.session, input) });
  await ctx.permission.hook("evaluate", async event => {
    if (event.action !== "shell" && event.action !== "bash") return;
    const scope = await guardScope(ctx.session, event.sessionID).catch(() => ({ registered: true }));
    if (!scope.registered) return;
    event.effect = "deny";
    event.message = "the registered lead requires the effect runtime; install .opencode/plugins dependencies before continuing";
  });
}

export default { id: "firstmate.native.v2", ...(runtime ? { effect } : { setup: missingRuntime }) };
