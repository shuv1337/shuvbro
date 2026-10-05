// Linux /proc watcher singleton evidence for the V2 acceptance suite.
// Count only after two stable snapshots agree; churn must not look like success.
import { readFileSync, readdirSync } from "node:fs";
import { pathToFileURL } from "node:url";

export async function countWatchers(state, {
  procRoot = "/proc", read = readFileSync, list = readdirSync,
  attempts = 8, delayMs = 25,
} = {}) {
  if (!state) throw new Error("watcher state directory is required");
  const readText = (pid, name) => read(`${procRoot}/${pid}/${name}`, "utf8");
  const stat = (pid) => {
    const text = readText(pid, "stat");
    const fields = text.slice(text.lastIndexOf(") ") + 2).trim().split(/\s+/);
    if (fields.length < 20 || !/^\d+$/.test(fields[1]) || !/^\d+$/.test(fields[19]) || !/^\d+$/.test(fields[6])) {
      throw new Error(`invalid stat for ${pid}`);
    }
    const forkWithoutExec = (BigInt(fields[6]) & 64n) !== 0n; // Linux PF_FORKNOEXEC
    return { parent: fields[1], start: fields[19], status: fields[0], forkWithoutExec,
      identity: `${fields[1]}:${fields[19]}:${forkWithoutExec}` };
  };
  const record = (pid, withEnv) => {
    const before = stat(pid);
    const cmd = readText(pid, "cmdline");
    let env = null;
    if (withEnv(cmd)) {
      try { env = readText(pid, "environ"); }
      catch (error) { if (error.code !== "EACCES") throw error; }
    }
    const after = stat(pid);
    if (after.identity !== before.identity || readText(pid, "cmdline") !== cmd) return null;
    return { pid, ...after, cmd, env };
  };
  const transient = (error) => ["ENOENT", "ESRCH", "EACCES"].includes(error.code);
  const servesHome = (env) => env !== null && env.split("\0").includes(`FM_STATE_OVERRIDE=${state}`);
  const isWatcher = (cmd) => /(?:^|\0)[^\0]*\/bin\/fm-watch\.sh(?:\0|$)/.test(cmd);
  let previous = null;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const roots = [];
    let stable = true;
    for (const pid of list(procRoot).filter((name) => /^\d+$/.test(name)).sort()) {
      // Most /proc entries belong to unrelated users. Only matching cmdlines
      // need environment access; an inaccessible unrelated entry is irrelevant.
      let cmd, env;
      try {
        cmd = readText(pid, "cmdline");
        if (!isWatcher(cmd)) continue;
        env = readText(pid, "environ");
      }
      catch (error) {
        if (transient(error)) {
          if (cmd && isWatcher(cmd)) stable = false;
          continue;
        }
        throw error;
      }
      if (!servesHome(env)) continue;
      try {
        const child = record(pid, () => true);
        if (!child || child.cmd !== cmd || child.env !== env) { stable = false; continue; }
        if (["Z", "X"].includes(child.status)) { stable = false; continue; }
        const parent = record(child.parent, (parentCmd) => parentCmd === child.cmd);
        // Verify the child still has the same identity and parent after reading
        // that parent. A missing/reused parent invalidates this entire sample.
        const after = record(pid, () => false);
        if (!parent || !after || BigInt(parent.start) > BigInt(child.start) ||
            after.identity !== child.identity || after.cmd !== child.cmd) {
          stable = false;
          continue;
        }
        // A Bash subshell retains its parent's command even after adoption by
        // init or a subreaper. PF_FORKNOEXEC survives adoption until exec.
        if (child.forkWithoutExec) continue;
        if (parent.cmd === child.cmd) {
          if (parent.env === null) { stable = false; continue; }
          if (servesHome(parent.env)) continue;
        }
        roots.push(`${pid}:${child.identity}:${parent.pid}:${parent.identity}:${child.cmd}`);
      } catch (error) {
        if (transient(error)) { stable = false; continue; }
        throw error;
      }
    }
    const snapshot = JSON.stringify(roots.sort());
    if (stable && snapshot === previous) return roots.length;
    previous = stable ? snapshot : null;
    if (attempt + 1 < attempts) await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  throw new Error(`watcher process identities did not stabilize after ${attempts} scans`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { console.log(`watchers=${await countWatchers(process.argv[2])}`); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
