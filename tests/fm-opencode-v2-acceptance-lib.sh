#!/usr/bin/env bash
# Shared fixtures for the OpenCode V2 shared-service acceptance suites.
# Sourced by tests/fm-opencode-v2-guard-acceptance.test.sh,
# tests/fm-opencode-v2-ownership-acceptance.test.sh and
# tests/fm-opencode-v2-shared-service-live.test.sh.
#
# Fixtures here reproduce host facts observed on shuvcode v2.0.22-shuv.1 and
# drive production entrypoints and helpers; they never reimplement shuvbro
# policy. The only production-specific knobs are:
#   FM_V2_TEST_SERVER_ENTRIES  colon-separated server plugin entry files to load
#                              (default: the shipped guard entry files); point it
#                              at the single V2 package server entry once it lands.
#   v2_register_lead / v2_retire_lead / v2_activation_env
#                              thin adapters to the session-lock library's
#                              registration writer and the launch helper's
#                              activation contract. Until those public interfaces
#                              exist they report "integration pending" and the
#                              dependent case is reported as pending, never pass.
# Set FM_V2_ACCEPT_STRICT=1 to turn every pending case into a failure.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

V2_PENDING=0
V2_FAILED=0

v2_pending() {  # <case> <missing interface>
  if [ "${FM_V2_ACCEPT_STRICT:-0}" = 1 ]; then
    printf 'not ok - %s: integration pending (%s)\n' "$1" "$2" >&2
    return 1
  fi
  printf 'pending - %s: integration pending (%s)\n' "$1" "$2"
  return 3
}

# Run each case in a subshell, counting failures and pendings separately.
v2_run_cases() {  # <case-function>...
  local t rc
  for t in "$@"; do
    rc=0
    ( "$t" ) || rc=$?
    case "$rc" in
      0) ;;
      3) V2_PENDING=$((V2_PENDING + 1)) ;;
      *) V2_FAILED=$((V2_FAILED + 1)) ;;
    esac
  done
  if [ "$V2_FAILED" -ne 0 ]; then
    printf 'not ok - %s case(s) failed, %s pending\n' "$V2_FAILED" "$V2_PENDING" >&2
    return 1
  fi
  [ "$V2_PENDING" -eq 0 ] || printf 'note: %s case(s) pending integration with the frozen V2 interfaces\n' "$V2_PENDING"
  return 0
}

v2_make_primary() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config" "$dir/projects/x"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$ROOT/bin/fm-cd-pretool-check.sh" \
    "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/"
  for lib in "$ROOT"/bin/fm-*-lib.sh; do cp "$lib" "$dir/bin/"; done
}

# A linked task worktree of a primary: the shape of a worker or scout location.
v2_make_worktree() {  # <primary> <dir>
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$1" worktree add -q "$2" 2>/dev/null
  mkdir -p "$2/bin" "$2/projects/x"
  cp "$1"/bin/* "$2/bin/"
}

v2_guard_runtime_ready() {
  [ -f "$ROOT/.opencode/plugins/node_modules/effect/package.json" ] && return 0
  [ -z "${CI:-}" ] || fail "effect runtime missing in CI; run: npm ci --prefix .opencode/plugins"
  return 1
}

v2_server_entries() {
  printf '%s' "${FM_V2_TEST_SERVER_ENTRIES:-$ROOT/.opencode/plugins/fm-primary-cd-check.js:$ROOT/.opencode/plugins/fm-primary-pretool-check.js}"
}

# Load every configured server entry against one location and run every
# registered tool execute.before hook for one shell event, like the host does.
# spec: {directory, out, sessions: {id: snapshot}, event: {tool, sessionID, input}}
# A snapshot is the native Session.Info shape the hook may fetch: id, parentID,
# location.directory, metadata. Records "allowed" or "failed" plus messages.
# V2_GUARD_PATH_PREFIX, when set, is prepended to PATH for the loaded entries and
# their helper subprocesses only (the driver itself runs on the resolved node).
V2_NODE_BIN=$(node -p process.execPath)
v2_drive_guard() {  # <spec-json>
  PATH="${V2_GUARD_PATH_PREFIX:+$V2_GUARD_PATH_PREFIX:}$PATH" \
    ENTRIES="$(v2_server_entries)" PLUGINS_DIR="$ROOT/.opencode/plugins" "$V2_NODE_BIN" --input-type=module - "$1" <<'EOF'
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const spec = JSON.parse(process.argv[2]);
const require = createRequire(process.env.PLUGINS_DIR + "/package.json");
const { Cause, Effect, Exit, Option } = await import(pathToFileURL(require.resolve("effect")).href);
const sessions = new Map(Object.entries(spec.sessions || {}));
const snapshot = (sessionID) => {
  if (!sessions.has(sessionID)) throw new Error("session not found");
  return sessions.get(sessionID);
};
const hooks = [];
const quietStream = { async *[Symbol.asyncIterator]() {} };
function makeCtx(effectStyle) {
  const location = { directory: spec.directory, project: { directory: spec.directory, canonical: spec.directory, id: "proj" } };
  if (effectStyle) {
    return {
      location,
      tool: { hook: (name, callback) => Effect.sync(() => { hooks.push({ name, callback, effectStyle }); }) },
      permission: { hook: () => Effect.void },
      session: { get: ({ sessionID }) => Effect.try(() => snapshot(sessionID)) },
      rpc: Object.assign(() => ({}), { register: () => Effect.succeed({ dispose: Effect.void }) }),
      event: { subscribe: () => quietStream },
    };
  }
  return {
    location,
    tool: { hook: async (name, callback) => { hooks.push({ name, callback, effectStyle }); return { dispose: async () => {} }; } },
    permission: { hook: async () => ({ dispose: async () => {} }) },
    session: { get: async ({ sessionID }) => snapshot(sessionID) },
    rpc: Object.assign(() => ({}), { register: async () => ({ dispose: async () => {} }) }),
    event: { subscribe: () => quietStream },
  };
}

for (const entry of process.env.ENTRIES.split(":").filter(Boolean)) {
  const mod = await import(pathToFileURL(entry).href);
  const def = mod.default;
  if (def?.effect) await Effect.runPromise(def.effect(makeCtx(true)));
  else if (def?.setup) await def.setup(makeCtx(false));
  else throw new Error(`${entry}: no V2 entrypoint`);
}
const before = hooks.filter((hook) => hook.name === "execute.before");
const result = { hooks: before.length, outcome: "allowed", messages: [] };
for (const hook of before) {
  const event = { id: "call_1", messageID: "msg_1", agent: "build", ...spec.event };
  if (hook.effectStyle) {
    const exit = await Effect.runPromiseExit(hook.callback(event));
    if (Exit.isFailure(exit)) {
      result.outcome = "failed";
      const failure = Cause.findErrorOption(exit.cause);
      result.messages.push(Option.isSome(failure) ? String(failure.value.message) : Cause.pretty(exit.cause));
    }
  } else {
    try { await hook.callback(event); } catch (error) { result.outcome = "failed"; result.messages.push(String(error?.message ?? error)); }
  }
}
writeFileSync(spec.out, JSON.stringify(result));
EOF
}

v2_shell_event() {  # <session-id> <command>
  jq -nc --arg s "$1" --arg c "$2" '{tool: "shell", sessionID: $s, input: {command: $c}}'
}

v2_root_session() {  # <id> <directory> [marker-session-id]
  if [ -n "${3:-}" ]; then
    jq -nc --arg id "$1" --arg d "$2" --arg m "$3" \
      '{id: $id, location: {directory: $d}, metadata: {firstmateV2Lead: {version: 1, sessionID: $m, claimID: "claim_fixture"}}}'
  else
    jq -nc --arg id "$1" --arg d "$2" '{id: $id, location: {directory: $d}, metadata: {}}'
  fi
}

v2_child_session() {  # <id> <parent> <directory> <inherited-marker-session-id>
  jq -nc --arg id "$1" --arg p "$2" --arg d "$3" --arg m "$4" \
    '{id: $id, parentID: $p, location: {directory: $d}, metadata: {firstmateV2Lead: {version: 1, sessionID: $m, claimID: "claim_fixture"}}}'
}

# --- integration adapters to Sol's frozen public interfaces -----------------
# Each returns 3 with a pending report until the production interface exists.

# Publish an exact lead registration (fixed registry record plus effective-state
# sidecar) for <session> with frozen <root>/<home>/<state>/<config>, owned by
# live process <owner-pid>, in registry namespace token <ns>.
v2_register_lead() {  # <case> <ns> <session> <root> <home> <state> <config> <owner-pid>
  v2_pending "$1" "session-lock registration writer (fixed registry + sidecar) not yet published"
}

# Mark an exact registration retired the way TUI exit does.
v2_retire_lead() {  # <case> <ns> <session>
  v2_pending "$1" "session-lock registration retire transition not yet published"
}

# Print the activation environment the launch helper exports for an exact
# session and owner, one NAME=value per line.
v2_activation_env() {  # <case> <session> <owner-pid>
  v2_pending "$1" "launch-helper activation variables not yet published"
}

# --- shared-service shell ancestry -------------------------------------------
# A fake ps tree in which every process is a shell whose parent is the shared
# `shuvcode serve --service` process FM_TEST_SERVICE_PID (reparented to pid 1),
# the observed shape of a model shell tool on the shared service.
v2_shared_service_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  "${FM_TEST_SERVICE_PID}:comm=") printf '%s\n' shuvcode ;;
  "${FM_TEST_SERVICE_PID}:args=") printf '%s\n' '/opt/shuvcode/bin/shuvcode serve --service' ;;
  "${FM_TEST_SERVICE_PID}:ppid=") printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' "$FM_TEST_SERVICE_PID" ;;
esac
SH
  chmod +x "$1/ps"
}

# Run bin/fm-lock.sh as a model shell of <session> on the shared service, with
# the shell's (possibly overwritten) FM_HOME.
v2_lock_as_session() {  # <home> <fakebin> <service-pid> <session-id>
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    FM_HOME="$1" PATH="$2:$PATH" FM_TEST_SERVICE_PID="$3" OPENCODE_SESSION_ID="$4" \
    bash "$ROOT/bin/fm-lock.sh" 2>&1
}
