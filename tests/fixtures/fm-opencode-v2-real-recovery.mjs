// Production coordinator/journal with unmodified real arm, watcher and recovery
// helpers. No fake arm or fabricated handling marker is used in this fixture.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";
import { assertTestRegistry, cleanupTestRegistry } from "../assets/fm-opencode-v2-test-registry.mjs";
assertTestRegistry();
const source = process.env.ROOT, lab = process.env.LAB;
const owner = await import(pathToFileURL(source + "/bin/fm-opencode-v2-owner.mjs"));
const { createWatchArmCoordinator } = await import(pathToFileURL(source + "/.opencode/plugins/lib/fm-watch-arm-v2.js"));
const { createAdmissionJournal } = await import(pathToFileURL(source + "/.opencode/plugins/fm-native-v2/admission.js"));
const { supervisionNeeded } = await import(pathToFileURL(source + "/.opencode/plugins/fm-native-v2/tui.js"));
const root = lab + "/root", home = lab + "/home", state = home + "/state";
const paths = { root, home, state, config: home + "/config" };
fs.mkdirSync(state, { recursive: true }); fs.mkdirSync(paths.config, { recursive: true });
fs.cpSync(source + "/bin", root + "/bin", { recursive: true }); fs.writeFileSync(root + "/AGENTS.md", "fixture\n");
fs.writeFileSync(state + "/fixture.meta", "kind=scout\n"); fs.writeFileSync(state + "/.wake-queue", "");
fs.mkdirSync(lab + "/cli");
// Observe the evaluator, spawned arm and confirmation helper environment while
// executing the real bash/helper bodies. Never log password values.
fs.writeFileSync(lab + "/cli/bash", `#!/bin/bash
case "\${1:-}" in
  -lc) probe=arm ;;
  -c) case "\${2:-}" in *fm-supervision-lib.sh*) probe=needed ;; *) probe= ;; esac ;;
  */bin/fm-watch-arm.sh) probe=confirmation ;;
  *) probe= ;;
esac
if [ -n "$probe" ]; then
  if [ "$probe" = needed ] && [ "\${FM_V2_SERVICE_URL:-}" != http://127.0.0.1:12345 ]; then
    echo needed wrong-endpoint >> '${state}/env-probes'; exit 98
  fi
  if [ "\${OPENCODE_PASSWORD+x}" = x ] || [ "\${OPENCODE_SERVER_PASSWORD+x}" = x ]; then
    echo "$probe credential-present" >> '${state}/env-probes'; exit 99
  fi
  echo "$probe safe" >> '${state}/env-probes'
fi
exec /bin/bash "$@"
`, { mode: 0o700 });
process.env.PATH = lab + "/cli:" + process.env.PATH;
process.env.FM_POLL = "1"; process.env.FM_HEARTBEAT = "999999"; process.env.FM_CHECK_INTERVAL = "1";
process.env.FM_STALE = "999999";
process.env.FM_HOME = home; process.env.FM_ROOT_OVERRIDE = root; process.env.FM_STATE_OVERRIDE = state; process.env.FM_CONFIG_OVERRIDE = paths.config;
process.env.FM_V2_REGISTRY_NAMESPACE += "-real";
assertTestRegistry();
process.env.OPENCODE_PASSWORD = "sentinel-not-a-real-credential";
process.env.OPENCODE_SERVER_PASSWORD = "second-sentinel-not-a-real-credential";
process.env.FM_V2_SERVICE_URL = "http://127.0.0.1:9999"; // inherited routing is not the frozen binding
const me = owner.identity(process.pid);
const record = { version: 1, sessionID: "ses_real_recovery", claimID: "c".repeat(48), ...paths, ownerPID: me.pid, ownerStart: me.start, hostBootID: me.boot, servicePID: me.pid, serviceStart: me.start, serviceURL: "http://127.0.0.1:12345", lifecycle: "active" };
process.env.OPENCODE_SESSION_ID = record.sessionID;
process.env.FM_V2_ACTIVATION = JSON.stringify(record);
owner.publish("claim", record); fs.writeFileSync(state + "/.lock", String(me.pid));
function read(path) { try { return fs.readFileSync(state + "/" + path, "utf8").trim(); } catch { return ""; } }
function running(pid) { try { owner.identity(Number(pid)); return true; } catch { return false; } }
async function until(test, message) {
  for (let i = 0; i < 240; i++) { if (await test()) return; await delay(100); }
  throw new Error(message + "; marker=" + read(".watcher-down"));
}
function verifyProcessEnvironment(pid) {
  const keys = fs.readFileSync(`/proc/${pid}/environ`, "utf8").split("\0").map(entry => entry.split("=")[0]);
  for (const key of ["OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD", "FM_V2_ACTIVATION"]) assert.equal(keys.includes(key), false, key + " reached owned supervision process");
}
const journalDir = state + "/.opencode-v2-admissions/" + createHash("sha256").update(record.sessionID).digest("hex");
const journalPath = value => journalDir + "/" + value.id + ".json";
let coordinator;
try {
  // A real registered custom check observes inherited watcher environment.
  fs.writeFileSync(state + "/probe.check.sh", `#!/bin/bash
if [ "\${OPENCODE_PASSWORD+x}" = x ] || [ "\${OPENCODE_SERVER_PASSWORD+x}" = x ]; then
  echo credential-present >> '${state}/check-probes'; exit 99
fi
echo safe >> '${state}/check-probes'
`, { mode: 0o700 });
  const { spawnSync } = await import("node:child_process");
  const registration = spawnSync(root + "/bin/fm-check-register.sh", ["probe"], { env: process.env, encoding: "utf8" });
  assert.equal(registration.status, 0, registration.stderr);
  await assert.rejects(supervisionNeeded(paths), /invalid frozen service endpoint/);
  assert.equal(await supervisionNeeded(record), true);
  const admitted = [], prepared = [], failures = [];
  const journal = createAdmissionJournal(paths, record.sessionID, async input => {
    const value = owner.readPrivate(journalDir + "/" + input.id + ".json");
    assert.equal(value.phase, "confirmed", "admission preceded successor confirmation");
    const token = read(".watcher-down"), generation = value.context.recovery.generation;
    assert.match(token, /^(pending|announced):handling:/); assert.equal(token.split(":").at(-1), generation);
    assert.equal(running(read(".watch.lock/pid")), true, "admission had no live successor");
    admitted.push(input); return { id: input.id };
  });
  const admission = { ...journal, prepare(...args) {
    const value = journal.prepare(...args);
    prepared.push({ value, token: read(".watcher-down") }); return value;
  } };
  const options = { owns: () => true, needs: () => supervisionNeeded(record), admission, processIdentity: owner.identity, failure: reason => failures.push(reason) };
  coordinator = createWatchArmCoordinator(paths, () => {}, options);
  assert.equal(await coordinator.ensureArmed(record.sessionID), "armed");
  const first = read(".watch.lock/pid"); verifyProcessEnvironment(first);
  const children = fs.readFileSync(`/proc/${process.pid}/task/${process.pid}/children`, "utf8").trim().split(/\s+/);
  const arm = children.find(pid => { try { return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes(root + "/bin/fm-watch-arm.sh"); } catch { return false; } });
  assert.ok(arm); verifyProcessEnvironment(arm);
  await until(() => read("check-probes"), "registered check was not executed");
  process.kill(Number(first), "SIGTERM");
  await until(() => admitted.length === 1 && owner.readPrivate(journalPath(prepared[0].value)).phase === "admitted", "real idle watcher death did not admit recovery");
  assert.equal(prepared.length, 1);
  assert.match(prepared[0].token, /^announced:downtime:/, "fixture did not exercise real no-row downtime path");
  assert.equal(prepared[0].value.rows.length, 0); assert.match(admitted[0].text, /WATCHER FIRED - drain the durable wake queue/);
  assert.doesNotMatch(admitted[0].text, /check: rearm-resurface/);
  const generation = prepared[0].value.context.recovery.generation, successor = read(".watch.lock/pid");
  assert.notEqual(successor, first); verifyProcessEnvironment(successor);
  for (let tick = 0; tick < 3; tick++) {
    await delay(2000); await coordinator.ensureArmed(record.sessionID); await coordinator.resumePending(record.sessionID);
    assert.equal(read(".watch.lock/pid"), successor); assert.equal(running(successor), true);
    assert.equal(read(".watcher-down").split(":").at(-1), generation); assert.equal(admitted.length, 1);
  }
  assert.equal(failures.length, 0, failures.join("\n"));
  assert.equal(prepared.length, 1, "reconciliation recreated the recovery presentation");
  assert.equal(read(".wake-queue"), "", "fixture consumed or invented canonical rows");
  assert.match(read("env-probes"), /needed safe/); assert.match(read("env-probes"), /arm safe/); assert.match(read("env-probes"), /confirmation safe/);
  assert.doesNotMatch(read("env-probes"), /credential-present/); assert.doesNotMatch(read("check-probes"), /credential-present/);
  await coordinator.cleanup(); coordinator = null;
  await until(() => !running(successor), "real successor survived cleanup");
  // Failed durable preparation must preserve the just-restored real successor.
  fs.writeFileSync(state + "/.watcher-down", "pending:downtime:gen-preparation-error\n");
  const preparationFailures = [];
  coordinator = createWatchArmCoordinator(paths, () => {}, { ...options,
    admission: { ...journal, prepare() { throw new Error("injected journal preparation failure"); } },
    failure: reason => preparationFailures.push(reason),
  });
  await coordinator.ensureArmed(record.sessionID);
  await until(() => preparationFailures.length === 1 && running(read(".watch.lock/pid")), "preparation failure retired restored continuity");
  const retained = read(".watch.lock/pid"), token = read(".watcher-down");
  for (let tick = 0; tick < 2; tick++) {
    await delay(2000); await coordinator.ensureArmed(record.sessionID);
    assert.equal(read(".watch.lock/pid"), retained); assert.equal(running(retained), true);
    assert.equal(read(".watcher-down"), token); assert.equal(preparationFailures.length, 1);
  }
  assert.equal(admitted.length, 1, "a preparation failure admitted a second presentation");
  await coordinator.cleanup(); coordinator = null; await until(() => !running(retained), "preparation-error successor survived cleanup");
  // An admitted no-row doorbell stays outstanding under a later unacked
  // generation. Once acked, it expires, but pending recoveries and claim
  // startup deduplication survive the same age-based cleanup pass.
  fs.utimesSync(journalPath(prepared[0].value), 1, 1);
  journal.pending(); assert.equal(owner.readPrivate(journalPath(prepared[0].value)).phase, "admitted");
  fs.writeFileSync(state + "/.watcher-down", "acked:downtime:gen-preparation-error\n");
  fs.utimesSync(journalPath(prepared[0].value), 1, 1);
  const pending = journal.prepare("pending recovery", "wake", { recovery: { generation: "gen-pending" } }); fs.utimesSync(journalPath(pending), 1, 1);
  const startup = journal.prepare("startup", "startup:retention"); fs.utimesSync(journalPath(startup), 1, 1);
  journal.pending(); assert.equal(fs.existsSync(journalPath(prepared[0].value)), false);
  assert.equal(fs.existsSync(journalPath(pending)), true); assert.equal(fs.existsSync(journalPath(startup)), true);
  // A confirmed presentation can outlive owner admission. Acking its episode
  // retires it, but not a fresh row or a different/unconfirmed generation.
  const recovered = journal.confirm(pending, { generation: "gen-pending" });
  fs.writeFileSync(state + "/.watcher-down", "acked:handling:other-generation\n");
  assert.equal(journal.acknowledged(recovered), false);
  fs.writeFileSync(state + "/.wake-queue", "100\t90\tsignal\ttask\tfresh wake\n");
  const rowWake = journal.prepare("fresh row wake", "wake", { recovery: { generation: "gen-pending" } });
  fs.writeFileSync(state + "/.watcher-down", "acked:handling:gen-pending\n");
  assert.equal(journal.acknowledged(recovered), true);
  await journal.deliver(recovered); assert.equal(admitted.length, 1, "acked recovery was redundantly admitted");
  assert.equal(owner.readPrivate(journalPath(pending)).phase, "acknowledged");
  assert.equal(journal.confirm(owner.readPrivate(journalPath(pending)), {}).phase, "acknowledged", "confirmation reopened a retired presentation");
  assert.equal(journal.pending().some(value => value.id === rowWake.id), true, "recovery ack lost a fresh real wake");
  await assert.rejects(journal.deliver(rowWake), /confirmation first/);
  assert.equal(journal.acknowledged(rowWake), false);
  fs.writeFileSync(state + "/.wake-queue", "");
  const unconfirmed = journal.prepare("unconfirmed", "wake", { recovery: { generation: "gen-unconfirmed" } });
  fs.writeFileSync(state + "/.watcher-down", "acked:handling:gen-unconfirmed\n");
  assert.equal(journal.acknowledged(unconfirmed), false, "ack bypassed successor confirmation");
  await assert.rejects(journal.deliver(unconfirmed), /confirmation first/);
  console.log("real idle watcher TERM: one generation/admission, confirmed live successor; preparation failure retains continuity; credentials absent from evaluator, arm, watcher and custom check; no-row retention passed");
} finally {
  await coordinator?.cleanup(); owner.publish("retire", record); cleanupTestRegistry(source);
}
