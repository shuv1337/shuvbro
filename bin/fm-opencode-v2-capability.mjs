// Read-only pre-dispatch probe. CLI: ROOT. Only --version/--help execute;
// never call api, debug paths, service discovery, or a managed/private server.
// Accept stable shuvcode V2 builds at/above the last qualified contract floor,
// subject to native CLI flags, the matching distribution's offline client
// contract, and the code root's pinned Effect guard runtime. No V1 fallback.
// The bundled client is exercised with an in-memory transport, not a server.
// Plugin event declarations are checked too. These are admission checks, not
// live behavioral qualification: permissions, hooks, restart settlement and
// TUI lifecycle still require the isolated live guards in runtime-backends.md.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { accessSync, constants, readFileSync, realpathSync } from "node:fs";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";

const floor = [2, 0, 22, 2];
const floorVersion = "2.0.22-shuv.2";
// Add exclusions only for demonstrated regressions, with the evidence/reason.
// None above the floor are currently known bad; a release bump is not a veto.
const knownBad = new Map();
const prefix = "opencode-v2 capability probe: ";

function installedPackage(executable, version) {
  const candidates = executable.includes("/") ? [resolve(executable)] :
    (process.env.PATH || "").split(delimiter).map(dir => resolve(dir, executable));
  let binary;
  for (const candidate of candidates) {
    try { accessSync(candidate, constants.X_OK); binary = realpathSync(candidate); break; } catch {}
  }
  if (!binary) throw new Error("cannot resolve the probed executable");
  // Handle both a launcher symlink and nested/hoisted native npm packages.
  for (let dir = dirname(binary); ; dir = dirname(dir)) {
    let pkg;
    try { pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8")); } catch {}
    if (pkg?.name === "shuvcode") {
      if (pkg.version !== version) throw new Error("executable and bundled client versions differ");
      return dir;
    }
    if (/^shuvcode-(linux|darwin|windows)-/.test(pkg?.name || "")) {
      if (pkg.version !== version) throw new Error("native package and executable versions differ");
      const sibling = join(dirname(dir), "shuvcode");
      let owner;
      try { owner = JSON.parse(readFileSync(join(sibling, "package.json"), "utf8")); } catch {}
      if (owner?.name === "shuvcode" && owner.version === version && owner.optionalDependencies?.[pkg.name] === version) return sibling;
    }
    if (dirname(dir) === dir) break;
  }
  throw new Error("the executable has no matching shuvcode package with an offline client");
}

async function probeClient(packageRoot) {
  const { OpenCode } = await import(pathToFileURL(join(packageRoot, "client/index.js")));
  if (typeof OpenCode?.make !== "function") throw new Error("missing offline OpenCode.make client");
  let calls = [];
  let responseStatus = 200;
  const client = OpenCode.make({ baseUrl: "http://capability.invalid", fetch: async (url, init) => {
    calls.push({ url: new URL(url), method: init.method, body: init.body === undefined ? undefined : JSON.parse(init.body) });
    return new Response(responseStatus === 204 ? null : '{"data":{}}', { status: responseStatus, headers: { "content-type": "application/json" } });
  } });
  async function check(operation, input, method, path, body, query = {}, status = 200) {
    calls = [];
    responseStatus = status;
    // Recent clients group the same message-list route under message.list.
    const member = operation === "session.message.list" && !client.session?.message?.list ? "message.list" : operation;
    const fn = member.split(".").reduce((value, key) => value?.[key], client);
    if (typeof fn !== "function") throw new Error("missing " + operation + " API capability");
    try { await fn(input); } catch { throw new Error("unusable " + operation + " offline client"); }
    const request = calls[0];
    if (calls.length !== 1 || request.method !== method || request.url.origin !== "http://capability.invalid" ||
      request.url.pathname !== path || !isDeepStrictEqual(Object.fromEntries(request.url.searchParams), query) ||
      !isDeepStrictEqual(request.body, body)) throw new Error("incompatible " + operation + " request contract");
  }
  const sessionID = "ses_capability", path = "/api/session/" + sessionID;
  const location = { directory: "/capability" }, model = { providerID: "probe", id: "model", variant: "low" };
  const metadata = { firstmateV2Lead: { probe: true } };
  await check("server.info", undefined, "GET", "/api/info");
  for (const [operation, route] of [["config.get", "/api/config"], ["model.list", "/api/model"], ["model.default", "/api/model/default"]]) {
    await check(operation, { location }, "GET", route, undefined, { "location[directory]": location.directory });
  }
  await check("session.create", { location, model }, "POST", "/api/session", { location, model });
  await check("session.get", { sessionID }, "GET", path);
  await check("session.active", undefined, "GET", "/api/session/active");
  await check("session.switchModel", { sessionID, model }, "POST", path + "/model", { model }, {}, 204);
  await check("session.update", { sessionID, metadata }, "PATCH", path, { metadata }, {}, 204);
  await check("session.environment", { sessionID, variables: { FM_HOME: "/capability" } }, "PUT", path + "/environment", { variables: { FM_HOME: "/capability" } }, {}, 204);
  for (const delivery of ["queue", "steer"]) {
    const body = { id: "msg_capability", text: "probe", delivery };
    await check("session.prompt", { sessionID, ...body }, "POST", path + "/prompt", body);
  }
  await check("session.interrupt", { sessionID, resume: false }, "POST", path + "/interrupt", undefined, { resume: "false" });
  await check("session.message.list", { sessionID, order: "desc", limit: 64 }, "GET", path + "/message", undefined, { order: "desc", limit: "64" });
  // No offline server introspection exists. Require the event surface shipped
  // with this exact package; live guards prove actual emission and semantics.
  const types = readFileSync(join(packageRoot, "client/generated/types.d.ts"), "utf8");
  for (const event of ["session.inbox.enqueued", ...["started", "succeeded", "failed", "interrupted"].map(state => "session.execution." + state)]) {
    if (!types.includes('"' + event + '"')) throw new Error("missing " + event + " event capability");
  }
}

export async function probeCapabilities(root, executable = "shuvcode") {
  function cli(args) {
    const result = spawnSync(executable, args, { encoding: "utf8", timeout: 5000, maxBuffer: 65536 });
    if (result.status !== 0 || result.signal) throw new Error(prefix + "cannot run shuvcode " + args.join(" ") + "; install a complete shuvcode V2 package before dispatch");
    return result.stdout;
  }
  const version = cli(["--version"]).trim();
  const parsed = /^shuvcode v(2)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-shuv\.([1-9]\d*)(?:\+[0-9A-Za-z.-]+)?$/.exec(version);
  if (!parsed) throw new Error(prefix + "unsupported target " + version + "; install stable shuvcode V2 (V1 opencode and non-shuvcode binaries are not supported)");
  const numbers = parsed.slice(1, 5).map(Number);
  const differing = numbers.findIndex((number, index) => number !== floor[index]);
  if (numbers.some(number => !Number.isSafeInteger(number)) || differing >= 0 && numbers[differing] < floor[differing]) {
    throw new Error(prefix + version + " is below the supported floor shuvcode v" + floorVersion + "; upgrade shuvcode before dispatch");
  }
  const build = version.slice("shuvcode v".length);
  const release = build.split("+")[0];
  if (knownBad.has(release)) throw new Error(prefix + "known-incompatible " + version + ": " + knownBad.get(release) + "; install a fixed build before dispatch");
  function flags(help, required) {
    for (const flag of required) if (!new RegExp("(?:^|\\s)" + flag + "(?:[\\s,=]|$)").test(help)) {
      throw new Error(prefix + "missing native " + flag + " launch/API capability in " + version + "; reinstall or upgrade shuvcode before dispatch");
    }
  }
  flags(cli(["--help"]), ["--server", "--session", "--auto"]);
  flags(cli(["api", "--help"]), ["--server", "--param", "--data"]);
  try { await probeClient(installedPackage(executable, build)); }
  catch (error) { throw new Error(prefix + error.message + "; reinstall the complete matching shuvcode npm package (including its client), or use a compatible build; no service was contacted"); }
  const runtimeRoot = join(resolve(root), ".opencode/plugins");
  try {
    const pkg = JSON.parse(readFileSync(join(runtimeRoot, "node_modules/effect/package.json"), "utf8"));
    const expected = JSON.parse(readFileSync(join(runtimeRoot, "package.json"), "utf8")).dependencies.effect;
    if (pkg.version !== expected) throw new Error("effect runtime does not match the pinned version");
    const require = createRequire(join(runtimeRoot, "package.json"));
    const { Data, Effect } = await import(pathToFileURL(require.resolve("effect")));
    if (typeof Data?.TaggedError !== "function" || !Effect?.void || ["gen", "promise", "tryPromise", "runPromise", "flatMap", "fail"].some(key => typeof Effect?.[key] !== "function")) throw new Error("effect native guard capabilities are missing");
  } catch (error) { throw new Error(prefix + error.message + "; run npm ci --prefix .opencode/plugins in the code root before dispatch"); }
  return { version, runtime: "effect", qualified: true };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await probeCapabilities(process.argv[2]))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
