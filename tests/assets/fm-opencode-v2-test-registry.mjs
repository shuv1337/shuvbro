import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
export function assertTestRegistry(existing = false) {
  const result = spawnSync("bash", [root + "tests/fm-opencode-v2-acceptance-lib.sh", "--assert-test-namespace", ...(existing ? ["--existing"] : [])], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr.trim() || "V2 test registry guard failed");
  const file = process.env.FM_V2_TEST_NAMESPACE_FILE;
  if (file && existsSync(file)) appendFileSync(file, process.env.FM_V2_REGISTRY_NAMESPACE + "\n");
}
export function cleanupTestRegistry(codeRoot = root) {
  assertTestRegistry(true);
  const file = process.env.FM_V2_TEST_NAMESPACE_FILE;
  // Shared service/TUI exits are test steps. The acceptance library retires
  // registered participants together at suite exit, never during a restart.
  if (file && existsSync(file) && readFileSync(file, "utf8").split("\n").includes(process.env.FM_V2_REGISTRY_NAMESPACE)) return;
  const result = spawnSync(process.execPath, [codeRoot + "/bin/fm-opencode-v2-owner.mjs", "cleanup-test-namespace"], { encoding: "utf8" });
  if (result.status === 0) return;
  throw new Error("V2 test namespace cleanup refused: " + result.stderr.trim());
}
