#!/usr/bin/env node
// Native ShuvBro NEW-home entrypoint. No legacy fleet initialization/controller.
// Usage: fm-native.mjs init --home NEW --project DIR --herdr-socket ABS
//   --herdr-session NONDEFAULT --parent-workspace ID [--role lead|secondmate]
//   [--host-id ID] [--shuvcode-command JSON_ARRAY] [--model PROVIDER/MODEL]
//   [--provider-url URL] [--auto]
// fm-native.mjs up --home HOME [--model MODEL] [--provider-url URL] [--auto]
// fm-native.mjs sync|watch|status --home HOME
// Keep watch running for 2-second heartbeats; up/sync are one-shot and status
// expires to unknown after 5 seconds. Stopping this adapter never stops work.
// fm-native.mjs control --home HOME -- NATIVE_SUBCOMMAND [typed CLI args...]
// fm-native.mjs cleanup|reopen --home HOME --entry EXACT_ENTRY_ID
// native-display.json owns presentation identity, pending operations and report
// high-water marks. Native settings/database own all execution/workflow state.
// Each display mutation is journaled first; a lost create/launch result remains
// uncertain rather than being repeated. Reopen is explicit and uses a new ID.
// Local destination-owned presentation only; run independently on each host.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";
import { access, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { createConnection } from "node:net";
import { hostname } from "node:os";
import { delimiter, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const methods = ["pane.bind_runtime", "pane.get_runtime", "pane.report_runtime", "pane.unbind_runtime"];
const profile = fileURLToPath(new URL("../profiles/native-shuvbro.json", import.meta.url));
const help = `Native ShuvBro (new homes only)\n${(await readFile(fileURLToPath(import.meta.url), "utf8")).split("\n").filter(line => line.startsWith("//")).map(line => line.slice(3)).join("\n")}\n`;
const argv = process.argv.slice(2);
const verb = argv.shift();
if (!verb || verb === "--help" || verb === "help") { process.stdout.write(help); process.exit(0); }

async function main() {
  const options = {}, tail = [];
  const permitted = new Set(["home", "project", "herdr-socket", "herdr-session", "parent-workspace", "role", "host-id", "shuvcode-command", "model", "provider-url", "entry", "auto"]);
  while (argv.length) {
    const key = argv.shift();
    if (key === "--") { tail.push(...argv); break; }
    if (!key.startsWith("--") || !permitted.has(key.slice(2)) || Object.hasOwn(options, key.slice(2))) throw new Error(`Unknown or repeated option ${key}`);
    options[key.slice(2)] = key === "--auto" ? true : argv.shift();
    if (options[key.slice(2)] === undefined || options[key.slice(2)] !== true && options[key.slice(2)].startsWith("--")) throw new Error(`Missing value for ${key}`);
  }
  if (!options.home || !isAbsolute(options.home)) throw new Error("--home must be an explicit absolute path");
  const home = resolve(options.home), file = join(home, "native-display.json");
  if (verb === "init") {
    for (const key of ["project", "herdr-socket", "herdr-session", "parent-workspace"]) if (!options[key]) throw new Error(`init requires --${key}`);
    if (!isAbsolute(options.project) || !isAbsolute(options["herdr-socket"]) || ["default", "main"].includes(options["herdr-session"]) || !/^[A-Za-z0-9_-]+$/.test(options["herdr-session"])) throw new Error("Use absolute project/socket paths and an explicit non-default Herdr session");
    if (!["lead", "secondmate"].includes(options.role ?? "lead")) throw new Error("role must be lead or secondmate");
    const command = options["shuvcode-command"] ? JSON.parse(options["shuvcode-command"]) : [await executable("shuvcode")];
    if (!Array.isArray(command) || !command.length || !command.every(item => typeof item === "string" && item.length > 0 && !/[\x00-\x1f\x7f]/.test(item) && !/^--(?:password|token|credential|api[-_]key|server-password)(?:=|$)/i.test(item)) || !isAbsolute(command[0])) throw new Error("shuvcode-command must be a credential-free argv array with an absolute executable");
    const config = { version: 1, home, command, project: resolve(options.project), role: options.role ?? "lead", hostID: options["host-id"] ?? hostname(), herdr: { socket: options["herdr-socket"], session: options["herdr-session"], parentWorkspaceID: options["parent-workspace"] }, init: nativeOptions(options), entries: {}, initialized: false };
    await mkdir(home, { mode: 0o700 }); // Existing legacy/native homes are never taken over.
    await save(file, config);
  }
  const journal = JSON.parse(await readFile(file, "utf8"));
  if (journal.version !== 1 || journal.home !== home || !journal.herdr || !Array.isArray(journal.command)) throw new Error("Not an exact native ShuvBro home");
  if (!["init", "up", "sync", "watch", "status", "control", "cleanup", "reopen"].includes(verb)) throw new Error(`Unknown native operation ${verb}`);
  if (verb === "control") {
    if (!journal.initialized) throw new Error("Native initialization is incomplete");
    if (!tail.length || ["init", "up", "attach", "presentation", "lead"].includes(tail[0]) || tail.some(item => item === "--home" || item.startsWith("--home="))) throw new Error("Use typed native subcommands; home/lead initialization and attachment have dedicated entrypoints");
    process.stdout.write(await native(journal, [...tail, "--home", home], false));
    return;
  }
  if (verb === "watch") {
    for (;;) {
      try { await locked(home, file, async current => { ready(current); await sync(current, file); output(current); }); }
      catch (error) { console.error(`Native display unavailable: ${error.message}`); }
      await new Promise(done => setTimeout(done, 2000));
    }
  }
  await locked(home, file, async current => {
    if (verb === "init") {
      await negotiate(current); // Refuse incompatible display before native init or any view.
      await herdr(current, "workspace.get", { workspace_id: current.herdr.parentWorkspaceID });
      await native(current, ["init", "--home", home, "--project", current.project, "--profile", profile, ...current.init], false);
      const settings = JSON.parse(await readFile(join(home, "settings.json"), "utf8"));
      if (typeof settings.pilotID !== "string" || !settings.pilotID) throw new Error("Native init did not return a home identity");
      current.homeID = settings.pilotID;
      current.initialized = true;
      await save(file, current);
      output(current);
      return;
    }
    ready(current);
    if (verb === "up") {
      await native(current, ["up", "--home", home, "--profile", profile, ...nativeOptions(options)], false);
      await sync(current, file);
      output(current);
      return;
    }
    if (verb === "status") { output(current); return; }
    if (verb === "cleanup" || verb === "reopen") {
      if (!options.entry || !current.entries[options.entry]) throw new Error("An exact recorded --entry is required");
      const entry = current.entries[options.entry];
      const projection = await presentation(current);
      const fact = projection.entries.find(item => item.id === options.entry);
      await negotiate(current);
      if (verb === "reopen") {
        if (entry.phase !== "closed" || !fact?.available || fact.retired) throw new Error("Reopen requires a closed display and an available exact native Session");
        if (!same(entry.attachment, attachment(current, fact))) throw new Error("Reopen attachment identity changed");
        current.entries[options.entry] = record(current, fact);
        await save(file, current);
        await reconcile(current, file, fact);
        output(current);
        return;
      }
      if (entry.phase === "closed") { output(current); return; }
      if (entry.phase === "close_pending") {
        try { await owned(current, entry); }
        catch (error) {
          if (!["not_found", "pane_not_found"].includes(error.code)) throw error;
          entry.phase = "closed";
          await save(file, current);
          output(current);
          return;
        }
      }
      if (!fact?.settled || !same(entry.attachment, attachment(current, fact))) throw new Error("Native execution is not positively settled at the exact recorded attachment");
      await owned(current, entry);
      entry.phase = "close_pending";
      await save(file, current);
      await herdr(current, "pane.close", { pane_id: entry.paneID });
      entry.phase = "closed";
      await save(file, current);
      output(current);
      return;
    }
    await sync(current, file);
    output(current);
  });
}

function ready(journal) {
  if (!journal.initialized) throw new Error("Native initialization is incomplete; retain this home for inspection and choose a new home");
}

async function locked(home, file, action) {
  const unlock = await lock(home);
  try { return await action(JSON.parse(await readFile(file, "utf8"))); }
  finally { await unlock(); }
}

function nativeOptions(options) {
  return ["model", "provider-url"].flatMap(key => options[key] ? [`--${key}`, options[key]] : []).concat(options.auto ? ["--auto"] : []);
}

async function executable(name) {
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    const path = resolve(directory, name);
    try { await access(path, constants.X_OK); return path; } catch (error) { if (!["ENOENT", "EACCES"].includes(error.code)) throw error; }
  }
  throw new Error(`${name} executable is unavailable`);
}

async function save(file, value) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  await writeFile(temporary, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
  await rename(temporary, file);
}

async function lock(home) {
  const directory = join(home, ".native-display-lock"), deadline = Date.now() + 10000;
  for (;;) {
    const staging = `${directory}.${randomUUID()}.tmp`;
    await mkdir(staging, { mode: 0o700 });
    await writeFile(join(staging, "pid"), String(process.pid), { mode: 0o600 });
    try { await rename(staging, directory); return () => rm(directory, { recursive: true }); }
    catch (error) { await rm(staging, { recursive: true }); if (!["EEXIST", "ENOTEMPTY"].includes(error.code)) throw error; }
    let pid;
    try { pid = Number(await readFile(join(directory, "pid"), "utf8")); }
    catch (error) { if (error.code === "ENOENT") continue; throw error; }
    if (!Number.isSafeInteger(pid) || pid < 2) throw new Error("Ambiguous native display lock; retain it for inspection");
    try { process.kill(pid, 0); }
    catch (alive) { if (alive.code !== "ESRCH") throw alive; await rm(directory, { recursive: true, force: true }); continue; }
    if (Date.now() > deadline) throw new Error("Native display adapter is busy");
    await new Promise(done => setTimeout(done, 100));
  }
}

async function native(journal, args, json) {
  const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(HERDR_|FM_)/.test(key)));
  return new Promise((resolveResult, reject) => {
    const child = spawn(journal.command[0], [...journal.command.slice(1), "supervisor", ...args], { env: environment, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    const timer = setTimeout(() => { child.kill("SIGTERM"); reject(new Error("Native CLI timed out; outcome may be uncertain")); }, 30000);
    child.stdout.on("data", data => { stdout += data; if (stdout.length > 4 * 1024 * 1024) child.kill(); });
    child.stderr.on("data", data => { stderr = (stderr + data).slice(-4096); });
    child.on("error", reject);
    child.on("close", code => {
      clearTimeout(timer);
      if (code !== 0) { reject(new Error(`Native CLI failed (${code}): ${stderr.trim()}`)); return; }
      try { resolveResult(json ? JSON.parse(stdout) : stdout); } catch (error) { reject(error); }
    });
  });
}

function herdr(journal, method, params) {
  return new Promise((resolveResult, reject) => {
    const id = randomUUID(), socket = createConnection(journal.herdr.socket);
    let received = "";
    const finish = (error, value) => { socket.destroy(); error ? reject(error) : resolveResult(value); };
    socket.setTimeout(5000, () => finish(new Error(`Herdr ${method} timed out; retain pending outcome`)));
    socket.on("error", reject);
    socket.on("connect", () => socket.write(JSON.stringify({ id, method, params }) + "\n"));
    socket.on("data", data => {
      received += data;
      if (received.length > 4 * 1024 * 1024) { finish(new Error("Herdr response too large")); return; }
      const lines = received.split("\n"); received = lines.pop();
      for (const line of lines) {
        try {
          const response = JSON.parse(line);
          if (response.id !== id) continue;
          if (response.error) { const error = new Error(`Herdr ${method}: ${response.error.code}: ${response.error.message}`); error.code = response.error.code; finish(error); return; }
          if (!response.result) throw new Error("Missing Herdr result");
          finish(undefined, response.result); return;
        } catch (error) { finish(error); return; }
      }
    });
    socket.on("end", () => finish(new Error(`Herdr ${method} disconnected; retain pending outcome`)));
  });
}

async function negotiate(journal) {
  const ping = await herdr(journal, "ping", {});
  if (!methods.every(method => ping.capabilities?.runtime_attachment_methods?.includes(method))) throw new Error("Herdr lacks required native runtime attachment methods");
}

async function presentation(journal) {
  const projection = await native(journal, ["presentation", "--home", journal.home, "--json"], true);
  if (projection.version !== 1 || projection.homeID !== journal.homeID || projection.home !== journal.home || !Array.isArray(projection.entries)) throw new Error("Native projection has a different home identity");
  const ids = new Set();
  for (const entry of projection.entries) {
    if (typeof entry.id !== "string" || !entry.id || ids.has(entry.id) || !["lead", "ship", "scout"].includes(entry.role) || !["idle", "working", "blocked", "done", "unknown"].includes(entry.state) || typeof entry.available !== "boolean" || typeof entry.settled !== "boolean" || typeof entry.retired !== "boolean" || entry.role !== "lead" && (typeof entry.title !== "string" || !entry.title.trim()) || !isAbsolute(entry.location) || entry.attachment?.provider !== "shuvcode" || entry.attachment.home_id !== journal.homeID || entry.attachment.session_id !== entry.sessionID || entry.attachment.location !== entry.location || entry.attachment.host_id !== "local") throw new Error("Invalid or nonlocal native presentation entry");
    ids.add(entry.id);
    const args = entry.attachment.attach_argv;
    const suffix = ["supervisor", "attach", "--home", journal.home, "--home-id", journal.homeID, "--session", entry.sessionID, "--location", entry.location];
    if (!Array.isArray(args) || !args.every(item => typeof item === "string" && !/[\x00-\x1f\x7f]/.test(item)) || !isAbsolute(args[0]) || !same(args.slice(-10), suffix)) throw new Error("Invalid credential-free exact native attachment argv");
    const prefix = args.slice(0, -10);
    if (!(prefix.length === 1 || prefix.length === 2 && isAbsolute(prefix[1]) || prefix.length === 5 && prefix[1] === "--no-env-file" && prefix[2] === "--preload" && isAbsolute(prefix[3]) && isAbsolute(prefix[4]))) throw new Error("Unsupported native attachment command prefix");
  }
  return projection;
}

function attachment(journal, entry) { return { ...entry.attachment, host_id: journal.hostID }; }
function same(left, right) { return isDeepStrictEqual(left, right); }
function record(journal, entry) { return { id: entry.id, role: entry.role, taskID: entry.taskID, sessionID: entry.sessionID, attachment: attachment(journal, entry), bindingID: `shuvbro:${journal.homeID}:${randomUUID()}`, phase: "new", seq: 0 }; }

async function owned(journal, entry) {
  const pane = (await herdr(journal, "pane.get", { pane_id: entry.paneID })).pane;
  if (pane?.pane_id !== entry.paneID || pane.workspace_id !== entry.workspaceID || pane.tab_id !== entry.tabID) throw new Error("Recorded presentation pane moved or changed placement; retain ambiguity");
  const binding = (await herdr(journal, "pane.get_runtime", { pane_id: entry.paneID })).binding;
  if (binding?.binding_id !== entry.bindingID || !same(binding.attachment, entry.attachment)) throw new Error("Recorded presentation runtime binding changed");
  return binding;
}

async function sync(journal, file) {
  const projection = await presentation(journal);
  await negotiate(journal); // No creations on old Herdr, even after runtime up.
  const failures = [];
  for (const fact of projection.entries) {
    try {
      if (!journal.entries[fact.id]) {
        if (!fact.available || fact.retired) continue;
        journal.entries[fact.id] = record(journal, fact);
        await save(file, journal);
      }
      await reconcile(journal, file, fact);
    } catch (error) { failures.push(`${fact.id}: ${error.message}`); }
  }
  for (const entry of Object.values(journal.entries)) {
    if (projection.entries.some(fact => fact.id === entry.id) || entry.phase !== "ready") continue;
    try { await refresh(journal, file, entry, { state: "unknown", label: "native entry unavailable" }); }
    catch (error) { failures.push(`${entry.id}: ${error.message}`); }
  }
  if (failures.length) throw new Error(failures.join("; "));
}

async function reconcile(journal, file, fact) {
  const entry = journal.entries[fact.id];
  if (!same(entry.attachment, attachment(journal, fact))) throw new Error(`Native attachment identity changed for ${fact.id}`);
  if (entry.phase === "closed") return;
  if (entry.phase === "create_pending") throw new Error(`Uncertain creation for ${fact.id}; retain journal and inspect Herdr before allocating another view`);
  if (entry.phase === "new") {
    if (!fact.available || fact.retired) return;
    const label = fact.role === "lead" ? (journal.role === "secondmate" ? "2ndmate" : "firstmate") : fact.title.slice(0, 100);
    await herdr(journal, "workspace.get", { workspace_id: journal.herdr.parentWorkspaceID });
    entry.phase = "create_pending";
    await save(file, journal);
    const created = await herdr(journal, "workspace.create", { source_workspace_id: journal.herdr.parentWorkspaceID, cwd: fact.location, focus: false, label });
    if (!created.root_pane?.pane_id || created.root_pane.workspace_id !== created.workspace?.workspace_id || created.root_pane.tab_id !== created.tab?.tab_id) throw new Error("Invalid created presentation topology; retain pending creation");
    entry.paneID = created.root_pane.pane_id; entry.workspaceID = created.workspace.workspace_id; entry.tabID = created.tab.tab_id;
    entry.phase = "bind_pending";
    await save(file, journal);
  }
  if (entry.phase === "bind_pending") {
    const result = await herdr(journal, "pane.bind_runtime", { pane_id: entry.paneID, binding_id: entry.bindingID, attachment: entry.attachment });
    if (!result.applied) throw new Error("Native binding was not applied");
    await owned(journal, entry);
    entry.phase = "bound";
    await save(file, journal);
  }
  if (entry.phase === "bound") {
    await owned(journal, entry);
    const processInfo = (await herdr(journal, "pane.process_info", { pane_id: entry.paneID })).process_info;
    if (processInfo?.foreground_processes?.some(process => same(process.argv, entry.attachment.attach_argv))) {
      // Herdr can restore a just-bound view before this journal resumes.
      entry.phase = "ready";
      await save(file, journal);
    } else {
      if (!processInfo?.shell_pid || processInfo.foreground_process_group_id !== processInfo.shell_pid || !Array.isArray(processInfo.foreground_processes) || processInfo.foreground_processes.some(process => process.pid !== processInfo.shell_pid)) throw new Error(`Presentation shell is not idle for ${fact.id}; refusing attach input into another foreground process`);
      entry.phase = "launch_pending";
      await save(file, journal);
      // This is solely the exact attach-only TUI view, never prompt admission.
      await herdr(journal, "pane.send_input", { pane_id: entry.paneID, text: entry.attachment.attach_argv.map(value => `'${value.replaceAll("'", "'\\''")}'`).join(" "), keys: ["Enter"] });
      entry.phase = "ready";
      await save(file, journal);
    }
  }
  if (entry.phase === "launch_pending") {
    await owned(journal, entry);
    const processes = (await herdr(journal, "pane.process_info", { pane_id: entry.paneID })).process_info?.foreground_processes;
    if (!processes?.some(process => same(process.argv, entry.attachment.attach_argv))) throw new Error(`Uncertain attach launch for ${fact.id}; it will not be submitted twice`);
    entry.phase = "ready";
    await save(file, journal);
  }
  if (entry.phase === "close_pending") {
    try { await owned(journal, entry); }
    catch (error) { if (!["not_found", "pane_not_found"].includes(error.code)) throw error; entry.phase = "closed"; await save(file, journal); return; }
    throw new Error(`Uncertain cleanup for ${fact.id}; repeat explicit cleanup after settlement`);
  }
  if (entry.phase === "ready") await refresh(journal, file, entry, fact);
}

async function refresh(journal, file, entry, fact) {
  try { await report(journal, file, entry, fact); }
  catch (error) {
    if (!["not_found", "pane_not_found"].includes(error.code)) throw error;
    entry.phase = "closed"; // Display disappeared; never substitute another running view.
    await save(file, journal);
  }
}

async function report(journal, file, entry, fact) {
  const binding = await owned(journal, entry);
  entry.seq = Math.max(entry.seq, binding.seq ?? 0) + 1;
  await save(file, journal);
  const result = await herdr(journal, "pane.report_runtime", { pane_id: entry.paneID, binding_id: entry.bindingID, seq: entry.seq, state: fact.state, ...(fact.label ? { label: fact.label } : {}), ttl_ms: 5000 });
  if (!result.applied || result.binding?.seq !== entry.seq || result.binding.binding_id !== entry.bindingID) throw new Error("Native report was stale or rejected; exact current binding requires reconciliation");
  entry.state = result.binding.state;
  await save(file, journal);
}

function output(journal) { process.stdout.write(JSON.stringify({ version: 1, homeID: journal.homeID, home: journal.home, herdr: journal.herdr, entries: Object.values(journal.entries) }) + "\n"); }
main().catch(error => { console.error(`Native ShuvBro: ${error.message}`); process.exitCode = 1; });
