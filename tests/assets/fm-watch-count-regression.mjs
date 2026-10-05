// Behavioral filesystem fixtures: mutate /proc entries at exact read boundaries.
import { spawn } from "node:child_process";
import { once } from "node:events";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { countWatchers } from "./fm-watch-count.mjs";

const home = "/fixture/state";
const watcher = "bash\0/fixture/bin/fm-watch.sh\0";
const root = mkdtempSync(join(tmpdir(), "fm-watch-count-"));
let caseNumber = 0;
async function test(label, run) {
  const procRoot = join(root, String(++caseNumber));
  mkdirSync(procRoot);
  const put = (pid, parent, start, cmd = watcher, state = home, flags = 0) => {
    const dir = join(procRoot, String(pid));
    mkdirSync(dir, { recursive: true });
    // The comm contains ')' and spaces, as a real /proc stat field may.
    const fields = ["S", parent, ...Array(17).fill(0), start, 0];
    fields[6] = flags;
    writeFileSync(join(dir, "stat"), `${pid} (watcher ) child) ${fields.join(" ")}\n`);
    writeFileSync(join(dir, "cmdline"), cmd);
    writeFileSync(join(dir, "environ"), `FM_STATE_OVERRIDE=${state}\0`);
  };
  put(1, 0, 1, "init\0");
  put(10, 1, 10, "bash\0");
  put(20, 10, 20);
  put(21, 20, 21);
  const options = { procRoot, delayMs: 0 };
  await run({ procRoot, put, options });
  console.log(`ok - watcher count: ${label}`);
}
try {
  await test("a stable watcher excludes its subshell and another home", async ({ put, options }) => {
    put(30, 10, 30, watcher, "/other/state");
    assert.equal(await countWatchers(home, options), 1);
  });
  await test("two genuine watchers remain two", async ({ put, options }) => {
    put(30, 10, 30);
    assert.equal(await countWatchers(home, options), 2);
  });
  await test("a parent exiting mid-read triggers a stable rescan", async ({ procRoot, put, options }) => {
    let scans = 0;
    let subshellEnvironReads = 0;
    let parentReadStarted = false;
    let fired = false;
    options.list = (path) => { scans++; return readdirSync(path); };
    options.read = (path, encoding) => {
      // After subshell 21's identity and environment are read, its parent 20
      // is read next. Remove both old entries between that parent's stat and
      // cmdline reads, and start a successor watcher.
      if (path === join(procRoot, "21/environ")) subshellEnvironReads++;
      if (!fired && subshellEnvironReads >= 2 && path === join(procRoot, "20/stat")) parentReadStarted = true;
      if (!fired && parentReadStarted && path === join(procRoot, "20/cmdline")) {
        fired = true;
        rmSync(join(procRoot, "20"), { recursive: true });
        rmSync(join(procRoot, "21"), { recursive: true });
        put(30, 10, 30);
      }
      return readFileSync(path, encoding);
    };
    assert.equal(await countWatchers(home, options), 1);
    assert.ok(parentReadStarted && fired, "must remove the parent during the subshell parent read");
    assert.ok(scans >= 3, "must invalidate the vanished-parent sample");
  });
  await test("a parent vanishing on every scan never counts its subshell as a root", async ({ procRoot, options }) => {
    let subshellEnvironReads = 0;
    let parentFailures = 0;
    options.list = (path) => { subshellEnvironReads = 0; return readdirSync(path); };
    options.read = (path, encoding) => {
      if (path === join(procRoot, "21/environ")) subshellEnvironReads++;
      if (subshellEnvironReads >= 2 && path === join(procRoot, "20/stat")) {
        parentFailures++;
        throw Object.assign(new Error("gone"), { code: "ENOENT" });
      }
      return readFileSync(path, encoding);
    };
    await assert.rejects(countWatchers(home, { ...options, attempts: 3 }), /did not stabilize after 3 scans/);
    assert.equal(parentFailures, 3, "every scan must reach the subshell parent read");
  });
  await test("a vanished candidate is tolerated", async ({ procRoot, options }) => {
    let fired = false;
    options.read = (path, encoding) => {
      if (!fired && path === join(procRoot, "21/environ")) {
        fired = true;
        rmSync(join(procRoot, "21"), { recursive: true });
      }
      return readFileSync(path, encoding);
    };
    assert.equal(await countWatchers(home, options), 1);
    assert.ok(fired);
  });
  await test("run-state changes keep a stable identity", async ({ procRoot, options }) => {
    let statReads = 0;
    options.read = (path, encoding) => {
      const value = readFileSync(path, encoding);
      if (path === join(procRoot, "20/stat") || path === join(procRoot, "10/stat")) {
        return value.replace(") S ", statReads++ % 2 ? ") R " : ") S ");
      }
      return value;
    };
    assert.equal(await countWatchers(home, { ...options, attempts: 3 }), 1);
  });
  await test("an executed watcher may be reparented", async ({ put, options }) => {
    put(30, 1, 30);
    assert.equal(await countWatchers(home, options), 2);
  });
  for (const parent of [1, 10]) {
    await test(`an adopted subshell alongside a live root is excluded (parent ${parent})`, async ({ put, options }) => {
      put(21, parent, 21, watcher, home, 64);
      assert.equal(await countWatchers(home, options), 1);
    });
    await test(`an adopted subshell alone is not a watcher (parent ${parent})`, async ({ procRoot, put, options }) => {
      rmSync(join(procRoot, "20"), { recursive: true });
      put(21, parent, 21, watcher, home, 64);
      assert.equal(await countWatchers(home, options), 0);
    });
  }
  for (const name of ["stat", "cmdline", "environ"]) {
    await test(`EACCES during a matching candidate's ${name} read triggers rescan`, async ({ procRoot, options }) => {
      let fired = false;
      let reads = 0;
      let scans = 0;
      options.list = (path) => { scans++; return readdirSync(path); };
      options.read = (path, encoding) => {
        if (path === join(procRoot, `20/${name}`) && ++reads === 2 && !fired) {
          fired = true;
          throw Object.assign(new Error("denied"), { code: "EACCES" });
        }
        return readFileSync(path, encoding);
      };
      assert.equal(await countWatchers(home, options), 1);
      assert.ok(fired && scans >= 3, "must reach the denied record read and invalidate its sample");
    });
  }
  await test("persistent matching-candidate access denial exhausts the bound", async ({ procRoot, options }) => {
    let fired = 0;
    options.read = (path, encoding) => {
      if (path === join(procRoot, "20/stat")) {
        fired++;
        throw Object.assign(new Error("denied"), { code: "EACCES" });
      }
      return readFileSync(path, encoding);
    };
    await assert.rejects(countWatchers(home, { ...options, attempts: 3 }), /did not stabilize/);
    assert.equal(fired, 6, "candidate and subshell parent reads must both be denied each scan");
  });
  await test("unexpected I/O errors abort instead of being treated as churn", async ({ procRoot, options }) => {
    let fired = false;
    options.read = (path, encoding) => {
      if (path === join(procRoot, "20/stat")) {
        fired = true;
        throw Object.assign(new Error("unexpected I/O failure"), { code: "EIO" });
      }
      return readFileSync(path, encoding);
    };
    await assert.rejects(countWatchers(home, options), /unexpected I.O failure/);
    assert.ok(fired);
  });
  await test("PID reuse during a read invalidates the identity", async ({ procRoot, put, options }) => {
    let scans = 0;
    let fired = false;
    let environmentReads = 0;
    options.list = (path) => { scans++; return readdirSync(path); };
    options.read = (path, encoding) => {
      const value = readFileSync(path, encoding);
      if (path === join(procRoot, "21/environ") && ++environmentReads === 2) {
        fired = true;
        put(21, 10, 50); // same PID and command, new identity and relationship
      }
      return value;
    };
    assert.equal(await countWatchers(home, options), 2);
    assert.ok(fired && scans >= 3);
  });
  await test("a reused parent cannot hide an older child", async ({ put, options }) => {
    put(20, 10, 50); // younger than child 21: cannot be its original parent
    await assert.rejects(countWatchers(home, { ...options, attempts: 3 }), /did not stabilize after 3 scans/);
  });
  await test("continuous churn exhausts the bound instead of reporting singleton success", async ({ procRoot, put, options }) => {
    let generation = 100;
    let scans = 0;
    options.list = (path) => { scans++; return readdirSync(path); };
    options.read = (path, encoding) => {
      const value = readFileSync(path, encoding);
      if (path === join(procRoot, "21/environ")) put(21, 20, generation++);
      return value;
    };
    await assert.rejects(countWatchers(home, { ...options, attempts: 3 }), /did not stabilize after 3 scans/);
    assert.equal(scans, 3);
  });
  // Real Linux processes prove PF_FORKNOEXEC and adoption rather than only
  // encoding those assumptions in filesystem fixtures.
  const bin = join(root, "bin");
  mkdirSync(bin);
  const script = join(bin, "fm-watch.sh");
  writeFileSync(script, '(sleep 30 & wait) &\necho $! > "$1"\nwait\n');
  const processes = [];
  const launch = async (name) => {
    const childFile = join(root, name);
    const process = spawn("bash", [script, childFile], {
      env: { ...globalThis.process.env, FM_STATE_OVERRIDE: home },
      detached: true, stdio: "ignore",
    });
    processes.push(process);
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        const child = readFileSync(childFile, "utf8").trim();
        if (child) return { process, child };
      } catch (error) { if (error.code !== "ENOENT") throw error; }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error("real watcher fixture did not start");
  };
  try {
    const original = await launch("original-child");
    const candidates = [String(original.process.pid), original.child];
    const options = { list: () => candidates };
    assert.equal(await countWatchers(home, options), 1);
    const exited = once(original.process, "exit");
    original.process.kill("SIGKILL");
    await exited;
    candidates.splice(0, 1);
    assert.equal(await countWatchers(home, options), 0, "real orphan alone must not count");
    const successor = await launch("successor-child");
    candidates.push(String(successor.process.pid), successor.child);
    assert.equal(await countWatchers(home, options), 1, "real successor plus orphan must count once");
    console.log("ok - watcher count: real Bash orphan alone and alongside a successor");
  } finally {
    for (const process of processes) {
      try { globalThis.process.kill(-process.pid, "SIGKILL"); }
      catch (error) { if (error.code !== "ESRCH") throw error; }
    }
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}
