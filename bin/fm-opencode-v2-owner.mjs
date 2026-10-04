// Supplemental V2 session-lock authority and its fixed discovery projection.
// Linux process birth is required; unsupported hosts refuse activation.
// CLI: identity PID | registry | read SESSION | helper STATE [acquire] | lead-endpoint STATE |
// claim/retire (strict record JSON on stdin, serialized with fm-wake-lib locks).
// api OPERATION PARAMS... (service binding JSON on stdin); attach SESSION
// BINDING_JSON (credential-free argument, preserving interactive terminal stdin).
// Native adapters import this owner; neither metadata nor RPC chooses read paths.
import * as fs from "node:fs";
import { userInfo } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";

const uid = process.getuid?.();
const codeRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const limit = 16384;
const idPattern = /^ses_[A-Za-z0-9_-]{1,160}$/;
const claimPattern = /^[a-f0-9]{48}$/;
export const markerKey = "firstmateV2Lead";

export function serviceURL(value) {
  if (typeof value !== "string" || value.length > 2048) throw new Error("invalid frozen service endpoint");
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.pathname !== "/" || url.search || url.hash) throw new Error("invalid frozen service endpoint");
  return url.origin;
}

// Credentials stay in the native managed registration, never in our proof.
// Explicit endpoints must be locally registered; discovery never starts a service.
export function registeredService(endpoint) {
  const paths = spawnSync("shuvcode", ["debug", "paths"], { encoding: "utf8", timeout: 5000, maxBuffer: limit });
  if (paths.status !== 0) throw new Error("cannot resolve native service registration");
  const state = paths.stdout.match(/^state\s+(.+)$/m)?.[1]?.trim();
  if (!state || !state.startsWith("/")) throw new Error("invalid native state path");
  const requested = endpoint === undefined ? undefined : serviceURL(endpoint);
  const names = requested ? fs.readdirSync(state).filter(name => /^service(?:-[A-Za-z0-9._-]+)?\.json$/.test(name)) : ["service.json"];
  for (const name of names) {
    let registration;
    try { registration = readPrivate(join(state, name)); } catch (error) { if (error.code === "ENOENT") continue; throw error; }
    if (requested && serviceURL(registration.url) !== requested) continue;
    const process = identity(registration.pid);
    if (typeof registration.password !== "string") throw new Error("invalid native service credential");
    return { ...process, serviceURL: serviceURL(registration.url), password: registration.password };
  }
  throw new Error("unregistered native service endpoint; start/register the intended local shared service first");
}

export function nativeAPI(record, operation, parameters = []) {
  if (serviceURL(record.serviceURL) !== record.serviceURL) throw new Error("invalid recorded native service endpoint");
  const service = registeredService(record.serviceURL);
  if (service.pid !== record.servicePID || service.start !== record.serviceStart || service.boot !== record.hostBootID) throw new Error("native endpoint registration is a different service incarnation");
  const result = spawnSync("shuvcode", ["api", "--server", record.serviceURL, operation, ...parameters], {
    env: { ...process.env, OPENCODE_PASSWORD: service.password }, encoding: "utf8", timeout: 10000, maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0 || result.signal) throw new Error("cannot verify native service operation " + operation);
  // These operations answer success with an empty (No Content) body.
  if (["session.environment", "session.switchModel"].includes(operation) && !result.stdout.trim()) return null;
  return JSON.parse(result.stdout);
}

export function identity(pid) {
  if (process.platform !== "linux" || !Number.isSafeInteger(Number(pid)) || Number(pid) < 2) throw new Error("V2 requires a local Linux process identity");
  const raw = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
  const text = raw.slice(raw.lastIndexOf(")") + 2).split(" ");
  if (!/^[A-Za-z]$/.test(text[0]) || !/^[0-9]+$/.test(text[19]) || !/^[0-9]+$/.test(text[1])) throw new Error("unreadable Linux process identity");
  if (["Z", "X"].includes(text[0])) throw Object.assign(new Error("process has exited"), { code: "ESRCH" });
  const ownerUID = fs.statSync(`/proc/${pid}`).uid;
  if (ownerUID !== uid) throw new Error("foreign execution user");
  const boot = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  if (!/^[a-f0-9-]{36}$/.test(boot)) throw new Error("unreadable Linux boot identity");
  return { pid: Number(pid), start: text[19], boot, parent: Number(text[1]) };
}

function directories(path, create = false, privateLeaf = false) {
  if (!path.startsWith("/") || resolve(path) !== path) throw new Error("noncanonical path");
  let current = "/";
  for (const part of path.split("/").filter(Boolean)) {
    current = join(current, part);
    if (create && !fs.existsSync(current)) fs.mkdirSync(current, { mode: 0o700 });
    const st = fs.lstatSync(current);
    const sharedTemporary = current === "/tmp" && st.uid === 0 && (st.mode & 0o1000);
    if (!st.isDirectory() || st.isSymbolicLink() || (st.mode & 0o022) && !sharedTemporary) throw new Error(`unsafe directory component: ${current}`);
    if (current === path && (st.uid !== uid || privateLeaf && (st.mode & 0o077))) throw new Error("unsafe private directory");
  }
}

export function registry() {
  const base = join(userInfo().homedir, ".local/state/shuvbro/opencode-v2");
  const namespace = process.env.FM_V2_REGISTRY_NAMESPACE || "default";
  if (!/^[a-zA-Z0-9_-]{1,64}$/.test(namespace)) throw new Error("invalid registry namespace");
  const dir = join(base, namespace);
  directories(dir, true, true);
  return dir;
}

function recordPath(sessionID) {
  if (!idPattern.test(sessionID)) throw new Error("invalid exact session ID");
  return join(registry(), createHash("sha256").update(sessionID).digest("hex") + ".json");
}

export function readPrivate(path) {
  directories(dirname(path));
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.uid !== uid || st.nlink !== 1 || (st.mode & 0o777) !== 0o600 || st.size > limit) throw new Error("unsafe record");
    const buffer = Buffer.alloc(limit + 1);
    const count = fs.readSync(fd, buffer, 0, buffer.length, 0);
    if (count > limit) throw new Error("oversize record");
    return JSON.parse(buffer.subarray(0, count).toString("utf8"));
  } finally { fs.closeSync(fd); }
}

export function writePrivate(path, value) {
  directories(dirname(path), true);
  const encoded = JSON.stringify(value) + "\n";
  if (Buffer.byteLength(encoded) > limit) throw new Error("oversize record publication");
  // Refuse replacing a malicious existing file, even though rename would not
  // follow its link. Missing files are the only acceptable read failure.
  try { readPrivate(path); } catch (error) { if (error.code !== "ENOENT") throw error; }
  const temporary = path + "." + randomBytes(12).toString("hex");
  const fd = fs.openSync(temporary, "wx", 0o600);
  try { fs.fchmodSync(fd, 0o600); fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); }
  finally { fs.closeSync(fd); }
  fs.renameSync(temporary, path);
  const dir = fs.openSync(dirname(path), "r");
  try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
}

export function schema(value) {
  const keys = ["version", "sessionID", "claimID", "root", "home", "state", "config", "ownerPID", "ownerStart", "hostBootID", "servicePID", "serviceStart", "serviceURL", "lifecycle"];
  if (!value || typeof value !== "object" || Object.keys(value).length !== keys.length || keys.some(key => !(key in value))) throw new Error("invalid V2 record schema");
  if (value.version !== 1 || !idPattern.test(value.sessionID) || !claimPattern.test(value.claimID) || !["claimed", "active", "retired"].includes(value.lifecycle)) throw new Error("invalid V2 registration");
  for (const field of ["root", "home", "state", "config"]) {
    if (typeof value[field] !== "string" || !value[field].startsWith("/") || resolve(value[field]) !== value[field] || value[field].length > 2048) throw new Error("invalid frozen path");
  }
  for (const field of ["ownerPID", "servicePID"]) if (!Number.isSafeInteger(value[field]) || value[field] < 2) throw new Error("invalid process ID");
  for (const field of ["ownerStart", "serviceStart"]) if (!/^[0-9]{1,32}$/.test(value[field])) throw new Error("invalid process birth");
  if (!/^[a-f0-9-]{36}$/.test(value.hostBootID)) throw new Error("invalid host identity");
  if (serviceURL(value.serviceURL) !== value.serviceURL) throw new Error("noncanonical frozen service endpoint");
  return value;
}

export function readRegistration(sessionID) {
  const value = schema(readPrivate(recordPath(sessionID)));
  if (value.sessionID !== sessionID) throw new Error("registration session mismatch");
  return value;
}

// Separate infrastructure failure from an exact record's corruption. Only
// the latter, or an exact native marker, justifies protecting a root session.
export function registrationPresence(sessionID) {
  const path = recordPath(sessionID);
  try { fs.lstatSync(path); return true; }
  catch (error) { if (error.code === "ENOENT") return false; throw error; }
}

export function live(value, servicePID = value.servicePID) {
  schema(value);
  const owner = identity(value.ownerPID), service = identity(servicePID);
  if (value.lifecycle === "retired" || owner.start !== value.ownerStart || owner.boot !== value.hostBootID || service.pid !== value.servicePID || service.start !== value.serviceStart || service.boot !== value.hostBootID) throw new Error("stale exact lead registration");
  return value;
}

function same(a, b) { schema(a); schema(b); return Object.keys(a).every(key => a[key] === b[key]); }

export function canonical(value, requireLock = true) {
  const sidecar = schema(readPrivate(join(value.state, ".opencode-v2-owner.json")));
  if (!same(value, sidecar)) throw new Error("V2 discovery/owner disagreement");
  if (requireLock) {
    directories(value.state);
    const file = join(value.state, ".lock");
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile() || st.uid !== uid || st.nlink !== 1 || st.size > 32 || fs.readFileSync(fd, "utf8").trim() !== String(value.ownerPID)) throw new Error("V2 lock disagreement");
    } finally { fs.closeSync(fd); }
  }
  return value;
}

// A home with a V2 lead owner record dispatches workers only on that lead's
// frozen endpoint. No owner record, or a retired one, keeps the default managed
// registration.
export function leadEndpoint(state) {
  const home = fs.realpathSync(state);
  let value;
  try { value = schema(readPrivate(join(home, ".opencode-v2-owner.json"))); }
  catch (error) { if (error.code === "ENOENT") return undefined; throw leadRefusal(error); }
  try {
    if (value.state !== home) throw new Error("owner record belongs to another state directory");
    if (value.lifecycle === "retired") return undefined;
    canonical(live(value));
  } catch (error) { throw leadRefusal(error); }
  return value.serviceURL;
}

function leadRefusal(error) {
  return new Error(`this home's V2 lead owner record is not a live canonical claim (${error.message}); relaunch or /firstmate-rebind the lead with bin/fm-opencode-v2-primary.sh before dispatching opencode-v2 workers`);
}

function ancestor(target) {
  let pid = process.pid;
  for (let i = 0; i < 64 && pid > 1; i++) {
    if (pid === target) return true;
    try { pid = identity(pid).parent; } catch { return false; }
  }
  return false;
}

export function helper(state, acquire = false) {
  const sessionID = process.env.OPENCODE_SESSION_ID || "";
  const value = live(readRegistration(sessionID));
  if (value.state !== state || process.env.FM_HOME !== value.home || (process.env.FM_ROOT_OVERRIDE || codeRoot) !== value.root || (process.env.FM_CONFIG_OVERRIDE || join(value.home, "config")) !== value.config) throw new Error("frozen V2 paths disagree with shell environment; another client may have replaced the environment");
  canonical(value, !acquire);
  if (!ancestor(value.ownerPID)) {
    if (!ancestor(value.servicePID)) throw new Error("helper has neither exact service nor owner ancestry");
    const api = operation => nativeAPI(value, operation, ["--param", `location[directory]=${value.root}`]);
    if (api("server.info").pid !== value.servicePID) throw new Error("native shell inventory belongs to a different service");
    const shells = api("shell.list").data;
    if (!Array.isArray(shells) || !shells.some(shell => shell.status === "running" && shell.cwd === value.root && shell.metadata?.sessionID === sessionID && typeof shell.command === "string" && Number.isSafeInteger(shell.pid) && ancestor(shell.pid))) throw new Error("native shell PID/cwd is not attributed to the exact lead session; environment alone cannot adopt it");
  }
  return value.ownerPID;
}

function mutate(action, value) {
  if (action === "cleanup-test-namespace") {
    if (!process.env.FM_V2_REGISTRY_NAMESPACE || process.env.FM_V2_REGISTRY_NAMESPACE === "default") throw new Error("cleanup requires an explicit non-default test namespace");
    const dir = registry();
    const records = fs.readdirSync(dir).filter(name => /^[a-f0-9]{64}\.json$/.test(name));
    for (const name of records) {
      const record = schema(readPrivate(join(dir, name)));
      let alive = false;
      try { alive = identity(record.ownerPID).start === record.ownerStart; } catch { /* dead */ }
      if (alive && record.lifecycle !== "retired") throw new Error("test namespace still has a live owner");
    }
    for (const name of records) fs.unlinkSync(join(dir, name));
    return { removed: records.length };
  }
  schema(value);
  const path = recordPath(value.sessionID);
  let old;
  try { old = readRegistration(value.sessionID); } catch (error) { if (error.code !== "ENOENT") throw error; }
  let homeOwner;
  try { homeOwner = schema(readPrivate(join(value.state, ".opencode-v2-owner.json"))); } catch (error) { if (error.code !== "ENOENT") throw error; }
  for (const candidate of [old, homeOwner]) {
    if (!candidate) continue;
    let alive = false;
    try { const found = identity(candidate.ownerPID); alive = found.start === candidate.ownerStart && found.boot === candidate.hostBootID; } catch { /* dead owner */ }
    if (alive && ["claimID", "ownerPID", "ownerStart", "hostBootID", "sessionID", "root", "home", "state", "config", "serviceURL"].some(field => candidate[field] !== value[field])) throw new Error("conflicting live V2 claim; observer cannot take over or change its frozen paths");
  }
  if (!ancestor(value.ownerPID) || identity(value.ownerPID).start !== value.ownerStart) throw new Error("claim caller is not activated TUI");
  if (action === "retire") {
    if (!old || old.claimID !== value.claimID || !homeOwner || homeOwner.claimID !== value.claimID) throw new Error("obsolete retirement");
    value = { ...value, lifecycle: "retired" };
  } else live(value);
  writePrivate(join(value.state, ".opencode-v2-owner.json"), value);
  writePrivate(path, value);
  return value;
}

export function publish(action, value) {
  const dir = registry();
  // Use the shared lock owner, not another bespoke stale-lock algorithm.
  // This one bounded user-wide mutation mutex serializes session and home
  // claims together, including external FM_HOME and same-session conflicts.
  const result = spawnSync("bash", ["-c", '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; node "$1/bin/fm-opencode-v2-owner.mjs" locked "$3"', "fm-v2-owner", codeRoot, join(dir, ".claims.lock"), action], { input: JSON.stringify(value), encoding: "utf8", timeout: 15000 });
  if (result.status !== 0) throw new Error(result.stderr?.trim() || "V2 ownership publication failed");
  const output = JSON.parse(result.stdout);
  if (action === "cleanup-test-namespace") {
    try { fs.rmdirSync(dir); } catch (error) { if (error.code !== "ENOTEMPTY") throw error; }
  }
  return action === "cleanup-test-namespace" ? output : schema(output);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [action, arg, mode] = process.argv.slice(2);
    let result;
    if (action === "identity") result = identity(Number(arg));
    else if (action === "service") {
      const service = registeredService(arg);
      result = { serviceURL: service.serviceURL, servicePID: service.pid, serviceStart: service.start, hostBootID: service.boot };
      if (nativeAPI(result, "server.info").pid !== service.pid) throw new Error("registered endpoint is not the connected execution service");
    }
    else if (action === "lead-endpoint") result = leadEndpoint(arg);
    else if (action === "registry") result = registry();
    else if (action === "api") result = nativeAPI(JSON.parse(fs.readFileSync(0, "utf8")), arg, process.argv.slice(4));
    else if (action === "attach") {
      if (!idPattern.test(arg || "")) throw new Error("invalid exact worker session");
      // Credential-free binding is an argument here: stdin must remain the
      // worker's actual terminal, not the JSON pipe used by short API calls.
      const record = JSON.parse(mode);
      if (nativeAPI(record, "server.info").pid !== record.servicePID) throw new Error("worker attachment endpoint changed service");
      const service = registeredService(record.serviceURL);
      if (service.pid !== record.servicePID || service.start !== record.serviceStart || service.boot !== record.hostBootID) throw new Error("worker attachment registration changed service incarnation");
      const attached = spawnSync("shuvcode", ["--server", record.serviceURL, "--auto", "--session", arg], {
        env: { ...process.env, OPENCODE_PASSWORD: service.password }, stdio: "inherit",
      });
      process.exitCode = attached.status ?? 1;
    }
    else if (action === "read") result = readRegistration(arg);
    else if (action === "probe") {
      let present = false;
      try { present = registrationPresence(arg); } catch { /* infrastructure is not authority */ }
      if (!present) process.exitCode = 3;
      else { readRegistration(arg); result = "registered"; }
    }
    else if (action === "helper") result = helper(arg, mode === "acquire");
    else if (action === "cleanup-test-namespace") result = publish(action, {});
    else if (action === "locked") result = mutate(arg, JSON.parse(fs.readFileSync(0, "utf8")));
    else if (["claim", "retire"].includes(action)) result = publish(action, JSON.parse(fs.readFileSync(0, "utf8")));
    else throw new Error("invalid V2 owner operation");
    if (result !== undefined) console.log(typeof result === "object" ? JSON.stringify(result) : result);
  } catch (error) { console.error(`error: ${error.message}`); process.exitCode = 1; }
}
