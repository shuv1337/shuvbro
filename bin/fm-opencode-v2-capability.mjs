// Read-only pre-dispatch probe: no managed-service discovery or auto-start.
// CLI: ROOT. Version drift requires explicit qualification, never V1 fallback.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export async function probeCapabilities(root, executable = "shuvcode") {
  function cli(args) {
    const result = spawnSync(executable, args, { encoding: "utf8", timeout: 5000, maxBuffer: 65536 });
    if (result.status !== 0 || result.signal) throw new Error("opencode-v2 capability probe cannot run shuvcode " + args.join(" ") + "; install the qualified executable before dispatch");
    return result.stdout;
  }
  const version = cli(["--version"]).trim();
  if (version !== "shuvcode v2.0.22-shuv.1") throw new Error("opencode-v2 capability probe: unqualified target " + version + "; use qualified shuvcode v2.0.22-shuv.1 or qualify the new build first");
  const help = cli(["--help"]);
  for (const flag of ["--server", "--session", "--auto"]) if (!help.includes(flag)) throw new Error("opencode-v2 capability probe: missing native " + flag + " launch capability");
  const runtimeRoot = join(resolve(root), ".opencode/plugins");
  try {
    const pkg = JSON.parse(readFileSync(join(runtimeRoot, "node_modules/effect/package.json"), "utf8"));
    const expected = JSON.parse(readFileSync(join(runtimeRoot, "package.json"), "utf8")).dependencies.effect;
    if (pkg.version !== expected) throw new Error("effect runtime does not match the pinned version");
    const require = createRequire(join(runtimeRoot, "package.json"));
    const { Data, Effect } = await import(pathToFileURL(require.resolve("effect")));
    if (typeof Data?.TaggedError !== "function" || ["gen", "promise", "tryPromise", "runPromise", "flatMap", "fail"].some(key => typeof Effect?.[key] !== "function")) throw new Error("effect native guard capabilities are missing");
  } catch (error) { throw new Error("opencode-v2 capability probe: " + error.message + "; run npm ci --prefix .opencode/plugins in the code root before dispatch"); }
  return { version, runtime: "effect", qualified: true };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await probeCapabilities(process.argv[2]))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
