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
    if (fields.length < 20 || !/^\d+$/.test(fields[1]) || !/^\d+$/.test(fields[19])) {
      throw new Error(`invalid stat for ${pid}`);
    }
    return `${fields[1]}:${fields[19]}:${fields[0]}`;
  };
  const record = (pid) => {
    const before = stat(pid);
    const cmd = readText(pid, "cmdline");
    const env = readText(pid, "environ");
    if (stat(pid) !== before || readText(pid, "cmdline") !== cmd) return null;
    const [parent, start, status] = before.split(":");
    return { pid, parent, start, status, cmd, env, identity: before };
  };
  const transient = (error) => ["ENOENT", "ESRCH"].includes(error.code);
  const servesHome = (process) => process.env.split("\0").includes(`FM_STATE_OVERRIDE=${state}`);
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
        if (transient(error) || error.code === "EACCES") continue;
        throw error;
      }
      if (!env.split("\0").includes(`FM_STATE_OVERRIDE=${state}`)) continue;
      try {
        const child = record(pid);
        if (!child || child.cmd !== cmd || child.env !== env) { stable = false; continue; }
        if (!servesHome(child)) continue;
        if (["Z", "X"].includes(child.status)) { stable = false; continue; }
        const parent = record(child.parent);
        // Verify the child still has the same identity and parent after reading
        // that parent. A missing/reused parent invalidates this entire sample.
        const after = record(pid);
        if (!parent || !after || BigInt(parent.start) > BigInt(child.start) ||
            after.identity !== child.identity || after.cmd !== child.cmd) {
          stable = false;
          continue;
        }
        if (parent.cmd === child.cmd && servesHome(parent)) continue;
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
