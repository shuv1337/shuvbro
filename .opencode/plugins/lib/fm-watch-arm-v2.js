import { spawn, spawnSync } from "node:child_process";
import { encodeFirstmateOperationalInput } from "./fm-operational-input.js";
import { isPrimaryRoot, positiveInteger, sessionOwnsLock, shouldArm } from "./fm-plugin-common.js";

const ARM_READY_TIMEOUT_DEFAULT_MS = process.platform === "win32" ? 35000 : 12000;
const ARM_READY_TIMEOUT_MS = positiveInteger("FM_OPENCODE_ARM_READY_TIMEOUT_MS", ARM_READY_TIMEOUT_DEFAULT_MS);
const ARM_RETIRE_TIMEOUT_MS = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const REARM_RETRY_BASE_MS = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const REARM_RETRY_MAX_MS = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const REARM_RETRY_LIMIT = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);

const owners = new Map();

export function registerWatchOwner(home, coordinator) {
  owners.set(home, coordinator);
}

export function watchOwnerFor(home) {
  return owners.get(home) || null;
}

export function unregisterWatchOwner(home, coordinator) {
  if (owners.get(home) === coordinator) owners.delete(home);
}

function retryDelay(attempt) {
  return Math.min(REARM_RETRY_MAX_MS, REARM_RETRY_BASE_MS * 2 ** Math.max(0, attempt - 1));
}

function wakePrompt(reason) {
  return `WATCHER FIRED - drain queued wakes with bin/fm-wake-drain.sh and handle the reported wake. Watcher continuity is plugin-owned.\n\n${reason}`;
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

export function createWatchArmCoordinator(paths, deliverPrompt) {
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
    stopped: false,
  };

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
          env: { ...process.env, FM_HOME: paths.home, FM_STATE_OVERRIDE: paths.state, FM_ROOT_OVERRIDE: paths.root },
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

  async function deliverActionableWake(sessionID, message, recovery) {
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(recovery);
      if (!confirmed.ok) {
        if (recovery.watcherPid) {
          try {
            process.kill(Number(recovery.watcherPid), 0);
          } catch {
            await retireArm(state.child);
          }
        }
        await sendPrompt(sessionID, wakePrompt(`${message}\n\n${confirmed.detail}`));
        return;
      }
    }
    await sendPrompt(sessionID, wakePrompt(message));
  }

  function surfaceFailure(sessionID, reason) {
    void sendPrompt(sessionID, wakePrompt(reason)).catch(() => {});
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

  async function scheduleRetry(sessionID, reason, predecessorArmPid) {
    if (state.stopped || state.child || state.retryTimer) return;
    state.retryFailures += 1;
    if (state.retryFailures > REARM_RETRY_LIMIT) {
      setArmStatus("failed");
      surfaceFailure(sessionID, `watcher: FAILED - OpenCode could not restore watcher continuity after ${REARM_RETRY_LIMIT} retries\n${reason}`);
      return;
    }
    setArmStatus("retrying");
    const timer = setTimeout(() => {
      if (state.retryTimer === timer) state.retryTimer = null;
      void ensureArm(sessionID, predecessorArmPid).then((status) => {
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
      ...process.env,
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
    const observeRecovery = () => {
      const recovery = `${stdout}\n${stderr}`.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) state.armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
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
        const restoration = restoreAfterActionableClose(sessionID, predecessor);
        state.restorationInFlight = restoration;
        void restoration
          .then(async (result) => {
            try {
              const message = result.failure ? `${classification.message}\n\n${result.failure}` : classification.message;
              await deliverActionableWake(sessionID, message, result.recovery);
            } finally {
              if (state.restorationInFlight === restoration) state.restorationInFlight = null;
            }
          })
          .catch((error) => {
            if (state.restorationInFlight === restoration) state.restorationInFlight = null;
            surfaceFailure(
              sessionID,
              `watcher: FAILED - OpenCode could not deliver an actionable wake\n${String(error?.message ?? error)}`,
            );
          });
        return;
      }
      if (state.restorationInFlight) {
        setArmStatus("failed");
        return;
      }
      void scheduleRetry(sessionID, classification.message, predecessor);
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
        String(armChild.pid ?? ""),
      );
    });
    return armChild;
  }

  async function beginArm(sessionID, predecessorArmPid) {
    if (state.stopped) return { status: "skipped", armChild: null };
    if (!sessionID) return { status: "skipped", armChild: null };
    if (!(await isPrimaryRoot(paths.root, paths.home))) return { status: "not-primary", armChild: null };
    if (!(await sessionOwnsLock(paths))) return { status: "read-only", armChild: null };
    if (state.child) return { status: "existing", armChild: state.child };
    if (state.retryTimer) return { status: "retrying", armChild: null };
    if (!shouldArm(paths)) return { status: "not-needed", armChild: null };
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
    ensureArmed: (sessionID) => ensureArm(sessionID),
    cleanup() {
      state.stopped = true;
      if (state.retryTimer) {
        clearTimeout(state.retryTimer);
        state.retryTimer = null;
      }
      if (state.child) {
        state.child.kill("SIGTERM");
        state.child = null;
      }
    },
  };
}
