import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { encodeFirstmateOperationalInput } from "./fm-operational-input.js";
import { isPrimaryRoot, positiveInteger, sessionOwnsLock, shouldArm } from "./fm-plugin-common.js";

const ARM_READY_TIMEOUT_DEFAULT_MS = process.platform === "win32" ? 35000 : 12000;
const ARM_READY_TIMEOUT_MS = positiveInteger("FM_OPENCODE_ARM_READY_TIMEOUT_MS", ARM_READY_TIMEOUT_DEFAULT_MS);
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function wakePrompt() {
  return "WATCHER FIRED - drain the durable wake queue with bin/fm-wake-drain.sh, handle the presented wakes, and run the acknowledgement command it prints. Watcher continuity is plugin-owned.";
}

function classifyArmClose(stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`;
  const reason = combined.split(/\r?\n/).find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line));
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - OpenCode arm child ended from ${signal}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined.trim() ? `\n${combined.trim()}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - OpenCode arm cycle ended without an actionable reason",
  };
}

export function createWatchArmCoordinator(paths, deliverPrompt, options = {}) {
  const childEnv = () => {
    const env = { ...process.env, FM_HOME: paths.home, FM_STATE_OVERRIDE: paths.state, FM_ROOT_OVERRIDE: paths.root, FM_CONFIG_OVERRIDE: paths.config };
    for (const key of ["FM_V2_ACTIVATION", "OPENCODE_PASSWORD", "OPENCODE_SERVER_PASSWORD"]) delete env[key];
    return env;
  };
  const state = {
    child: null,
    armStatus: "idle",
    retryTimer: null,
    retryFailures: 0,
    launchInFlight: null,
    restorationInFlight: null,
    armClose: new WeakMap(),
    armReadiness: new WeakMap(),
    armRecovery: new WeakMap(),
    processProofs: new Map(),
    stopped: false,
  };

  // Native process-exit disposal cannot await the arm's shell trap. Retain
  // immutable process births, not a home-wide PID search or unbound kill.
  function rememberProcess(pid) {
    if (!options.processIdentity || !pid) return;
    for (const [previous, proof] of state.processProofs) {
      try {
        const current = options.processIdentity(previous);
        if (current.start !== proof.start || current.boot !== proof.boot) state.processProofs.delete(previous);
      } catch { state.processProofs.delete(previous); }
    }
    try { state.processProofs.set(Number(pid), options.processIdentity(Number(pid))); } catch { /* already exited */ }
  }
  function cleanupSync() {
    state.stopped = true;
    if (state.retryTimer) clearTimeout(state.retryTimer);
    state.retryTimer = null;
    for (const [pid, expected] of state.processProofs) {
      try {
        const current = options.processIdentity(pid);
        if (current.pid === expected.pid && current.start === expected.start && current.boot === expected.boot) process.kill(pid, "SIGTERM");
      } catch { /* gone or birth changed: never signal a reused PID */ }
    }
  }

  function handlingGeneration() {
    try { return readFileSync(`${paths.state}/.watcher-down`, "utf8").trim().match(/^(?:pending|announced):(?:handling|downtime):([A-Za-z0-9._-]+)$/)?.[1]; }
    catch { return undefined; }
  }

  function setArmStatus(status) {
    state.armStatus = status;
  }

  function waitForArmReady(armChild) {
    const readiness = state.armReadiness.get(armChild);
    if (!readiness) return Promise.resolve("failed");
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady("timeout"), ARM_READY_TIMEOUT_MS);
      timer.unref();
      void readiness.then((status) => {
        clearTimeout(timer);
        resolveReady(status);
      });
    });
  }

  async function sendPrompt(sessionID, text) {
    const encoded = await encodeFirstmateOperationalInput(paths.root, "watcher", text);
    await deliverPrompt(sessionID, encoded);
  }

  function confirmHandlingDelivery(recovery) {
    try {
      const result = spawnSync(
        "bash",
        [`${paths.root}/bin/fm-watch-arm.sh`, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
        {
          cwd: paths.root,
          encoding: "utf8",
          env: childEnv(), timeout: ARM_READY_TIMEOUT_MS,
        },
      );
      if (result.status === 0) return { ok: true, detail: "" };
      const stderr = String(result.stderr || "").trim();
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`,
      };
    } catch (error) {
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${String(error?.message ?? error)}`,
      };
    }
  }

  function confirmHandlingDeliveryWithRetry(recovery) {
    const snapshot = () => state.armRecovery.get(state.child) ?? recovery;
    const first = confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  async function deliverActionableWake(sessionID, recovery, saved) {
    if (state.stopped || options.owns && !options.owns()) return;
    if (options.admission?.acknowledged(saved)) return;
    if (options.admission && !recovery) throw new Error("V2 successor has no verifiable recovery generation; pending admission retained");
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(recovery);
      if (!confirmed.ok) {
        if (options.admission) throw new Error(confirmed.detail);
        if (recovery.watcherPid) {
          try {
            process.kill(Number(recovery.watcherPid), 0);
          } catch {
            await retireArm(state.child);
          }
        }
        await sendPrompt(sessionID, `WATCHER FAILURE - drain the durable wake queue with bin/fm-wake-drain.sh and inspect the recovery failure.\n\n${confirmed.detail}`);
        return;
      }
    }
    if (options.admission) {
      await options.admission.deliver(options.admission.confirm(saved, recovery));
      return;
    }
    await sendPrompt(sessionID, wakePrompt());
  }

  function surfaceFailure(sessionID, reason, detail) {
    if (options.failure) { options.failure(reason, detail); return; }
    void sendPrompt(sessionID, `WATCHER FAILURE - drain the durable wake queue with bin/fm-wake-drain.sh and inspect the recovery failure.\n\n${reason}`).catch(() => {});
  }

  function waitForRetry(attempt) {
    return new Promise((resolveWait) => {
      const timer = setTimeout(resolveWait, retryDelay(attempt));
      timer.unref();
    });
  }

  async function retireArm(armChild) {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = state.armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), ARM_RETIRE_TIMEOUT_MS);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  function restorationFailure(status) {
    if (status === "read-only") {
      return "watcher: FAILED - OpenCode cannot restore continuity because this session is not bound to this plugin instance";
    }
    return `watcher: FAILED - OpenCode could not verify a ready successor watcher (${status || "idle"})`;
  }

  async function restoreAfterActionableClose(sessionID, predecessorArmPid) {
    let failure = "";
    for (let attempt = 0; attempt <= REARM_RETRY_LIMIT; attempt += 1) {
      const { status, armChild } = await ensureArm(sessionID, predecessorArmPid, true);
      if (status === "armed") return { failure: "", recovery: state.armRecovery.get(armChild) };
      if (status === "wake") return { failure: "", recovery: state.armRecovery.get(armChild) };
      failure = restorationFailure(status);
      if (!(await retireArm(armChild))) {
        setArmStatus("failed");
        return {
          failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity because the unready successor arm did not exit within ${ARM_RETIRE_TIMEOUT_MS}ms`,
        };
      }
      if (status === "read-only" || status === "not-primary" || status === "skipped") break;
      if (attempt === REARM_RETRY_LIMIT) break;
      await waitForRetry(attempt + 1);
    }
    setArmStatus("failed");
    return { failure: `${failure}\nwatcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries` };
  }

  async function scheduleRetry(sessionID, reason) {
    if (state.stopped || state.child || state.retryTimer) return;
    state.retryFailures += 1;
    if (state.retryFailures > REARM_RETRY_LIMIT) {
      setArmStatus("failed");
      surfaceFailure(sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`, { permanent: true });
      return;
    }
    setArmStatus("retrying");
    const timer = setTimeout(() => {
      if (state.retryTimer === timer) state.retryTimer = null;
      // A failed close did not deliver a handling presentation. An ordinary
      // arm must resurface downtime/queued rows, even if its watcher survived.
      void ensureArm(sessionID).then((status) => {
        if (["armed", "starting", "wake"].includes(status)) return;
        surfaceFailure(sessionID, `watcher: FAILED - OpenCode could not launch a continuity retry (${status})`);
      });
    }, retryDelay(state.retryFailures));
    timer.unref();
    state.retryTimer = timer;
  }

  function observeArmOutput(stdout, stderr, settleReadiness) {
    const combined = `${stdout}\n${stderr}`;
    if (combined.split(/\r?\n/).some((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line))) {
      setArmStatus("wake");
      settleReadiness("wake");
      return;
    }
    if (combined.split(/\r?\n/).some((line) => /^watcher: (?:started|attached)\b/.test(line))) {
      setArmStatus("armed");
      settleReadiness("armed");
      return;
    }
    if (combined.split(/\r?\n/).some((line) => /^watcher: healthy\b/.test(line))) {
      setArmStatus("external");
      settleReadiness("external");
      return;
    }
    if (combined.split(/\r?\n/).some((line) => /^watcher: FAILED/.test(line))) {
      setArmStatus("failed");
      settleReadiness("failed");
    }
  }

  function spawnArm(sessionID, predecessorArmPid = "") {
    setArmStatus("starting");
    const env = {
      ...childEnv(),
      FM_HOME: paths.home,
      FM_ROOT_OVERRIDE: paths.root,
      FM_STATE_OVERRIDE: paths.state,
      FM_CONFIG_OVERRIDE: paths.config,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn(
      "bash",
      ["-lc", 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_ROOT_OVERRIDE/bin/fm-watch-arm.sh" --restart'],
      {
        cwd: paths.root,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    state.child = armChild;
    rememberProcess(armChild.pid);
    let stdout = "";
    let stderr = "";
    let settled = false;
    let resolveClosed = null;
    let readinessSettled = false;
    let resolveReadiness = null;
    const readiness = new Promise((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    state.armReadiness.set(armChild, readiness);
    const settleReadiness = (status) => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(status);
    };
    const closed = new Promise((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    state.armClose.set(armChild, closed);
    const releaseChild = () => {
      if (state.child === armChild) state.child = null;
    };
    let watcherCaptured = false;
    const observeRecovery = () => {
      const ownedWatcher = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+)\b/m);
      if (ownedWatcher && !watcherCaptured) { watcherCaptured = true; rememberProcess(ownedWatcher[1]); }
      const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) state.armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      else {
        const ready = `${stdout}\n${stderr}`.match(/^watcher: (?:started|attached) pid=([0-9]+)\b/m);
        if (!ready) return;
        try {
          const marker = readFileSync(`${paths.state}/.watcher-down`, "utf8").trim();
          const generation = marker.match(/^(?:pending|announced):(?:handling|downtime):([A-Za-z0-9._-]+)$/)?.[1];
          if (generation) state.armRecovery.set(armChild, { watcherPid: ready[1], generation });
        } catch { /* confirmation is required; missing evidence cannot admit */ }
      }
    };
    armChild.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      observeRecovery();
      observeArmOutput(stdout, stderr, settleReadiness);
    });
    armChild.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      observeRecovery();
      observeArmOutput(stdout, stderr, settleReadiness);
    });
    armChild.on("close", (code, signal) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      releaseChild();
      const classification = classifyArmClose(stdout, stderr, code, signal);
      settleReadiness(classification.kind === "actionable" ? "wake" : "failed");
      const predecessor = String(armChild.pid ?? "");
      if (state.stopped) return;
      if (classification.kind === "actionable") {
        if (state.restorationInFlight) return;
        state.retryFailures = 0;
        setArmStatus("wake");
        const restoration = (async () => {
          let saved, preparationError;
          try {
            saved = options.admission
               ? options.admission.prepare(await encodeFirstmateOperationalInput(paths.root, "watcher", wakePrompt()), "wake", { predecessorArmPid: predecessor, recovery: { generation: handlingGeneration() } })
              : undefined;
          } catch (error) { preparationError = error.message; state.unpreparedWake = { predecessor }; }
          const result = await restoreAfterActionableClose(sessionID, predecessor);
          return { ...result, saved, preparationError };
        })();
        state.restorationInFlight = restoration;
        void restoration
          .then(async (result) => {
            try {
              if (state.stopped) return;
              if (options.admission && result.failure) throw Object.assign(new Error(result.failure + (result.preparationError ? "\n" + result.preparationError : "")), { nonRecoverable: true });
              if (result.preparationError && result.recovery?.generation) {
                try { result.saved = options.admission.prepare(await encodeFirstmateOperationalInput(paths.root, "watcher", wakePrompt()), "wake", { predecessorArmPid: predecessor, recovery: result.recovery }); }
                catch (error) { throw Object.assign(error, { nonRecoverable: true }); }
                state.unpreparedWake = null;
              } else if (result.preparationError) {
                // Journal failure must not destroy restored continuity or mint
                // a fresh downtime generation on every reconciliation tick.
                throw Object.assign(new Error(result.preparationError), { nonRecoverable: true });
              }
              if (result.failure) {
                surfaceFailure(sessionID, result.failure, { permanent: true });
                return;
              }
              await deliverActionableWake(sessionID, result.recovery, result.saved);
            } finally {
              if (state.restorationInFlight === restoration) state.restorationInFlight = null;
            }
          })
          .catch((error) => {
            if (state.restorationInFlight === restoration) state.restorationInFlight = null;
            surfaceFailure(
              sessionID,
              `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
              { permanent: error.nonRecoverable === true },
            );
          });
        return;
      }
      if (state.restorationInFlight) {
        setArmStatus("failed");
        return;
      }
      void scheduleRetry(sessionID, classification.message);
    });
    armChild.on("error", (error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      releaseChild();
      settleReadiness("failed");
      if (state.stopped) return;
      if (state.restorationInFlight) {
        setArmStatus("failed");
        return;
      }
      void scheduleRetry(
        sessionID,
        `watcher: FAILED - OpenCode arm child failed: ${error.message}`,
      );
    });
    return armChild;
  }

  async function beginArm(sessionID, predecessorArmPid) {
    if (state.stopped) return { status: "skipped", armChild: null };
    if (!sessionID) return { status: "skipped", armChild: null };
    if (!options.owns && !(await isPrimaryRoot(paths.root, paths.home))) return { status: "not-primary", armChild: null };
    if (!(await (options.owns ? options.owns() : sessionOwnsLock(paths)))) return { status: "read-only", armChild: null };
    if (state.child) return { status: "existing", armChild: state.child };
    if (state.retryTimer) return { status: "retrying", armChild: null };
    if (!(await (options.needs ? options.needs() : shouldArm(paths)))) return { status: "not-needed", armChild: null };
    if (state.stopped) return { status: "skipped", armChild: null };
    return { status: "spawned", armChild: spawnArm(sessionID, predecessorArmPid) };
  }

  function armAttempt(status, armChild, includeArmChild) {
    return includeArmChild ? { status, armChild } : status;
  }

  async function ensureArm(sessionID, predecessorArmPid = "", includeArmChild = false) {
    let launchResult = null;
    if (!state.launchInFlight) {
      const launch = beginArm(sessionID, predecessorArmPid);
      state.launchInFlight = launch;
      try {
        launchResult = await launch;
      } finally {
        if (state.launchInFlight === launch) state.launchInFlight = null;
      }
    } else {
      launchResult = await state.launchInFlight;
    }
    const armChild = launchResult.armChild;
    if (!armChild) {
      return armAttempt(launchResult.status, null, includeArmChild);
    }
    return armAttempt(await waitForArmReady(armChild), armChild, includeArmChild);
  }

  return {
    cleanupSync,
    ensureArmed: (sessionID) => ensureArm(sessionID),
    hasUnpreparedWake: () => !!state.unpreparedWake,
    async resumePending(sessionID) {
      if (!options.admission || state.restorationInFlight || state.stopped) return;
      const pending = options.admission.pending().filter(value => value.kind === "wake");
      if (!pending.length && !state.unpreparedWake) return;
      const result = await restoreAfterActionableClose(sessionID, "");
      if (result.failure) throw Object.assign(new Error(result.failure), { nonRecoverable: true });
      if (state.unpreparedWake) {
        const { predecessor } = state.unpreparedWake;
        try {
          pending.push(options.admission.prepare(await encodeFirstmateOperationalInput(paths.root, "watcher", wakePrompt()), "wake", { predecessorArmPid: predecessor, recovery: result.recovery || { generation: handlingGeneration() } }));
          state.unpreparedWake = null;
        } catch (error) { throw Object.assign(error, { nonRecoverable: true }); }
      }
      for (const saved of pending) {
        if (state.stopped) return;
        await deliverActionableWake(sessionID, result.recovery, saved);
      }
    },
    async cleanup() {
      state.stopped = true;
      if (state.retryTimer) {
        clearTimeout(state.retryTimer);
        state.retryTimer = null;
      }
      if (state.launchInFlight) await state.launchInFlight;
      if (state.child && !(await retireArm(state.child))) throw new Error("V2 old arm did not retire within its bounded deadline");
      state.child = null;
    },
  };
}
