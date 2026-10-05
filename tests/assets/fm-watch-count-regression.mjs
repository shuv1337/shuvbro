// Behavioral filesystem fixtures: mutate /proc entries at exact read boundaries.
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
  const put = (pid, parent, start, cmd = watcher, state = home) => {
    const dir = join(procRoot, String(pid));
    mkdirSync(dir, { recursive: true });
    // The comm contains ')' and spaces, as a real /proc stat field may.
    const fields = ["S", parent, ...Array(17).fill(0), start, 0];
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
  await test("another home's vanished candidate cannot destabilize this home", async ({ procRoot, put, options }) => {
    put(30, 10, 30, watcher, "/other/state");
    options.read = (path, encoding) => {
      if (path === join(procRoot, "30/stat")) throw Object.assign(new Error("gone"), { code: "ENOENT" });
      return readFileSync(path, encoding);
    };
    assert.equal(await countWatchers(home, options), 1);
  });
  await test("two genuine watchers remain two", async ({ put, options }) => {
    put(30, 10, 30);
    assert.equal(await countWatchers(home, options), 2);
  });
  await test("a parent exiting mid-read triggers a stable rescan", async ({ procRoot, put, options }) => {
    let scans = 0;
    let parentReads = 0;
    let fired = false;
    options.list = (path) => { scans++; return readdirSync(path); };
    options.read = (path, encoding) => {
      // Root 20's initial read and its own two reads precede the subshell's
      // parent read. Remove both old entries exactly at that parent read.
      if (path === join(procRoot, "20/cmdline") && ++parentReads === 4) {
        fired = true;
        rmSync(join(procRoot, "20"), { recursive: true });
        rmSync(join(procRoot, "21"), { recursive: true });
        put(30, 10, 30);
      }
      return readFileSync(path, encoding);
    };
    assert.equal(await countWatchers(home, options), 1);
    assert.ok(fired && scans >= 3, "must invalidate the vanished-parent sample");
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
  await test("an inaccessible reparenting parent still counts its watcher", async ({ procRoot, put, options }) => {
    put(30, 1, 30);
    options.read = (path, encoding) => {
      if (path === join(procRoot, "1/environ")) throw Object.assign(new Error("denied"), { code: "EACCES" });
      return readFileSync(path, encoding);
    };
    assert.equal(await countWatchers(home, options), 2);
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
} finally {
  rmSync(root, { recursive: true, force: true });
}
