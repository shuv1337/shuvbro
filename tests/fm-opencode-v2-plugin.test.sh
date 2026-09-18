#!/usr/bin/env bash
# Credential-free unit tests for OpenCode V2 / shuvcode plugin setup().
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-plugin)
export NODE_NO_WARNINGS=1

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
}

drive_v2() {
  local plugin=$1
  shift
  PLUGIN="$plugin" node --input-type=module - "$@" <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const spec = JSON.parse(process.argv[2]);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
if (!mod.default || typeof mod.default.setup !== "function") {
  throw new Error("missing V2 default.setup");
}

const prompts = [];
const queue = [];
let notify = null;
const sessions = new Map(Object.entries(spec.sessions || {}));
const abort = new AbortController();

const ctx = {
  location: {
    directory: spec.directory,
    project: { directory: spec.canonical || spec.directory, canonical: spec.canonical || spec.directory, id: "proj" },
  },
  event: {
    subscribe({ signal } = {}) {
      const stop = signal || abort.signal;
      return {
        async *[Symbol.asyncIterator]() {
          while (!stop.aborted) {
            if (queue.length) {
              yield queue.shift();
              continue;
            }
            await new Promise((resolve) => {
              notify = resolve;
              if (stop.aborted) resolve();
            });
          }
        },
      };
    },
  },
  session: {
    async prompt(request) {
      prompts.push(request);
      if (spec.failPrompt) throw new Error("admission failed");
      return { id: "msg_test" };
    },
    async get({ sessionID }) {
      if (!sessions.has(sessionID)) throw new Error("missing session");
      return sessions.get(sessionID);
    },
  },
};

const cleanup = await mod.default.setup(ctx);
await new Promise((resolve) => setTimeout(resolve, 50));
for (const event of spec.events || []) {
  queue.push(event);
  notify?.();
}
await new Promise((resolve) => setTimeout(resolve, spec.settleMs || 400));
if (spec.cleanup) {
  if (typeof cleanup !== "function") throw new Error("setup did not return cleanup");
  cleanup();
}
writeFileSync(spec.out, JSON.stringify({ prompts, cleaned: Boolean(spec.cleanup) }));
abort.abort();
notify?.();
EOF
}

# The guard plugins deny through the Effect runtime pinned in
# .opencode/plugins/package.json, the same install a shuvcode lead needs. CI
# installs it, so there a missing runtime is a failure rather than a skip.
guard_runtime_ready() {
  [ -f "$ROOT/.opencode/plugins/node_modules/effect/package.json" ] && return 0
  [ -z "${CI:-}" ] || fail "effect runtime missing in CI; run: npm ci --prefix .opencode/plugins"
  printf 'note: %s needs the effect runtime (npm ci --prefix .opencode/plugins)\n' "$1"
  return 1
}

# Runs a guard plugin's Effect entrypoint the way shuvcode does: run the
# registration Effect, then run the registered execute.before hook for one tool
# event and record the Exit.
drive_v2_guard() {
  local plugin=$1
  shift
  PLUGIN="$plugin" PLUGINS_DIR="$ROOT/.opencode/plugins" node --input-type=module - "$@" <<'EOF'
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const spec = JSON.parse(process.argv[2]);
const require = createRequire(process.env.PLUGINS_DIR + "/package.json");
const { Cause, Effect, Exit, Option } = await import(pathToFileURL(require.resolve("effect")).href);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const hooks = [];
const ctx = {
  location: {
    directory: spec.directory,
    project: { directory: spec.directory, canonical: spec.directory, id: "proj" },
  },
  tool: {
    hook: (name, callback) => Effect.sync(() => {
      hooks.push({ name, callback });
    }),
  },
};

await Effect.runPromise(mod.default.effect(ctx));
const hook = hooks.find((item) => item.name === "execute.before");
if (!hook) throw new Error("missing tool execute.before hook");
const exit = await Effect.runPromiseExit(hook.callback(spec.toolEvent));
const result = { hooks: hooks.map((item) => item.name) };
if (Exit.isSuccess(exit)) {
  result.outcome = "allowed";
} else {
  const failure = Cause.findErrorOption(exit.cause);
  if (Option.isSome(failure)) {
    result.outcome = "failed";
    result.tag = failure.value._tag;
    result.message = failure.value.message;
  } else {
    result.outcome = "defect";
    result.message = Cause.pretty(exit.cause);
  }
}
writeFileSync(spec.out, JSON.stringify(result));
EOF
}

install_guard_helpers() {
  local repo=$1
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$ROOT/bin/fm-cd-pretool-check.sh" \
    "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-cd-command-policy.mjs" "$repo/bin/"
}

guard_tool_event() {  # <dir> <out> <tool> <command>
  jq -nc --arg dir "$1" --arg out "$2" --arg tool "$3" --arg command "$4" \
    '{directory: $dir, out: $out, toolEvent: {tool: $tool, sessionID: "ses_lead", input: {command: $command}}}'
}

test_v2_watch_arm_does_not_cross_own_sessions() {
  local repo home out status result
  repo="$TMP_ROOT/watch-arm-primary"
  home="$TMP_ROOT/watch-arm-home"
  make_primary "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed %s %s\n' "${FM_HOME:-missing}" "${FM_STATE_OVERRIDE:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-operational-input.sh"
  log="$TMP_ROOT/watch-arm.log"
  out="$TMP_ROOT/watch-arm-out.json"
  status=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" drive_v2 "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      settleMs: 800,
      sessions: {
        ses_other: { id: "ses_other", location: { directory: "/tmp/other-project" } }
      },
      events: [
        { type: "session.execution.succeeded", data: { sessionID: "ses_other" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "V2 watch-arm foreign session should run"
  [ ! -f "$log" ] || fail "foreign session armed the watcher: $(cat "$log")"
  status=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" drive_v2 "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      settleMs: 800,
      sessions: {
        ses_lead: { id: "ses_lead", location: { directory: $dir } }
      },
      events: [
        { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "V2 watch-arm lead session should run"
  result=$(cat "$out")
  [ -f "$log" ] || fail "bound lead session did not arm: $result"
  grep -qx "armed $home $home/state" "$log" \
    || fail "arm child did not receive the FM_HOME home and its state dir: $(cat "$log")"
  printf '%s' "$result" | jq -e '.prompts | all(.sessionID == "ses_lead")' >/dev/null \
    || fail "a prompt targeted a foreign session: $result"
  printf '%s' "$result" | jq -e '.prompts | all(.delivery == "queue")' >/dev/null \
    || fail "a wake prompt used default steer: $result"
  pass "OpenCode V2 watch-arm binds one location and does not cross-own"
}

test_v2_watch_arm_cleanup_stops_children() {
  local repo home out status result
  repo="$TMP_ROOT/watch-arm-cleanup"
  home="$TMP_ROOT/watch-arm-cleanup-home"
  make_primary "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
printf 'watcher: started pid=$$\n'
sleep 30
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-operational-input.sh"
  out="$TMP_ROOT/watch-arm-cleanup.json"
  status=0
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" drive_v2 "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      cleanup: true,
      sessions: { ses_lead: { id: "ses_lead", location: { directory: $dir } } },
      events: [ { type: "session.execution.failed", data: { sessionID: "ses_lead", error: { name: "UnknownError" } } } ]
    }')" || status=$?
  expect_code 0 "$status" "V2 watch-arm cleanup should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.cleaned == true' >/dev/null \
    || fail "cleanup was not invoked: $result"
  pass "OpenCode V2 watch-arm setup returns cleanup"
}

test_v2_turnend_queues_follow_up_for_bound_session() {
  local repo out status result
  repo="$TMP_ROOT/turnend-primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard-fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf '\u2063FIRSTMATE_OP: v1 turn-end-guard: '
cat
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-operational-input.sh"
  out="$TMP_ROOT/turnend-out.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      settleMs: 600,
      sessions: {
        ses_lead: { id: "ses_lead", location: { directory: $dir } },
        ses_other: { id: "ses_other", location: { directory: "/tmp/other" } }
      },
      events: [
        { type: "session.execution.succeeded", data: { sessionID: "ses_other" } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "V2 turnend setup should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.prompts | length == 1' >/dev/null \
    || fail "expected one turnend prompt, got $result"
  printf '%s' "$result" | jq -e '.prompts[0].sessionID == "ses_lead"' >/dev/null \
    || fail "turnend targeted the wrong session: $result"
  printf '%s' "$result" | jq -e '.prompts[0].delivery == "queue"' >/dev/null \
    || fail "turnend prompt did not set delivery queue: $result"
  pass "OpenCode V2 turnend queues a follow-up only for the bound session"
}

test_v2_sessionstart_does_not_mark_failed_admission() {
  local repo out status result
  repo="$TMP_ROOT/nudge-primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf 'nudge-text\n'
SH
  chmod +x "$repo/bin/fm-sessionstart-nudge.sh"
  out="$TMP_ROOT/nudge-out.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      failPrompt: true,
      sessions: { ses_lead: { id: "ses_lead", location: { directory: $dir } } },
      events: [
        { type: "session.created", data: { sessionID: "ses_lead", location: { directory: $dir } } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "V2 sessionstart setup should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.prompts | length == 2' >/dev/null \
    || fail "failed admission must not consume the session: $result"
  printf '%s' "$result" | jq -e '.prompts[0].delivery == "queue"' >/dev/null \
    || fail "nudge prompt did not set delivery queue: $result"
  pass "OpenCode V2 sessionstart retries after failed admission and handles resume"
}

test_v2_sessionstart_ignores_foreign_session() {
  local repo out status result
  repo="$TMP_ROOT/nudge-foreign"
  make_primary "$repo"
  cat > "$repo/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
printf 'nudge-text\n'
SH
  chmod +x "$repo/bin/fm-sessionstart-nudge.sh"
  out="$TMP_ROOT/nudge-foreign.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      sessions: { ses_other: { id: "ses_other", location: { directory: "/tmp/other" }, parentID: null } },
      events: [ { type: "session.created", data: { sessionID: "ses_other", location: { directory: "/tmp/other" } } } ]
    }')" || status=$?
  expect_code 0 "$status" "V2 sessionstart foreign session should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.prompts | length == 0' >/dev/null \
    || fail "foreign session was nudged: $result"
  pass "OpenCode V2 sessionstart ignores sessions at another location"
}

test_v2_cd_guard_fails_bare_cd_with_typed_tool_error() {
  local repo out status result
  guard_runtime_ready "cd-guard Effect denial" || return 0
  repo="$TMP_ROOT/cd-guard-primary"
  make_primary "$repo"
  install_guard_helpers "$repo"
  mkdir -p "$repo/projects/x"
  out="$TMP_ROOT/cd-guard-deny.json"
  status=0
  drive_v2_guard "$ROOT/.opencode/plugins/fm-primary-cd-check.js" \
    "$(guard_tool_event "$repo" "$out" shell "cd projects/x")" || status=$?
  expect_code 0 "$status" "V2 cd-guard Effect entrypoint should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.hooks == ["execute.before"]' >/dev/null \
    || fail "cd-guard registered unexpected hooks: $result"
  printf '%s' "$result" | jq -e '.outcome == "failed" and .tag == "Tool.Error" and (.message | length > 0)' >/dev/null \
    || fail "bare cd was not rejected as a typed Tool.Error: $result"

  out="$TMP_ROOT/cd-guard-allow.json"
  status=0
  drive_v2_guard "$ROOT/.opencode/plugins/fm-primary-cd-check.js" \
    "$(guard_tool_event "$repo" "$out" shell "git -C projects/x status")" || status=$?
  expect_code 0 "$status" "V2 cd-guard should evaluate an allowed command"
  jq -e '.outcome == "allowed"' "$out" >/dev/null \
    || fail "cd-guard rejected a command that does not relocate the shell: $(cat "$out")"

  out="$TMP_ROOT/cd-guard-other-tool.json"
  status=0
  drive_v2_guard "$ROOT/.opencode/plugins/fm-primary-cd-check.js" \
    "$(guard_tool_event "$repo" "$out" read "cd projects/x")" || status=$?
  expect_code 0 "$status" "V2 cd-guard should ignore a non-shell tool"
  jq -e '.outcome == "allowed"' "$out" >/dev/null \
    || fail "cd-guard evaluated a non-shell tool: $(cat "$out")"
  pass "OpenCode V2 cd-guard rejects a bare cd as a typed Tool.Error and passes other commands"
}

test_v2_pretool_fails_compound_backgrounded_arm_with_typed_tool_error() {
  local repo out status result
  guard_runtime_ready "watcher-arm Effect denial" || return 0
  repo="$TMP_ROOT/pretool-primary"
  make_primary "$repo"
  install_guard_helpers "$repo"
  out="$TMP_ROOT/pretool-deny.json"
  status=0
  drive_v2_guard "$ROOT/.opencode/plugins/fm-primary-pretool-check.js" \
    "$(guard_tool_event "$repo" "$out" shell "echo ok; bin/fm-watch-arm.sh --restart &")" || status=$?
  expect_code 0 "$status" "V2 pretool Effect entrypoint should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.outcome == "failed" and .tag == "Tool.Error" and (.message | length > 0)' >/dev/null \
    || fail "backgrounded arm inside a compound command was not rejected as a typed Tool.Error: $result"

  out="$TMP_ROOT/pretool-allow.json"
  status=0
  drive_v2_guard "$ROOT/.opencode/plugins/fm-primary-pretool-check.js" \
    "$(guard_tool_event "$repo" "$out" shell "echo ok")" || status=$?
  expect_code 0 "$status" "V2 pretool should evaluate an allowed command"
  jq -e '.outcome == "allowed"' "$out" >/dev/null \
    || fail "pretool rejected an unrelated command: $(cat "$out")"
  pass "OpenCode V2 pretool rejects a compound backgrounded arm as a typed Tool.Error"
}

test_v2_named_v1_factory_still_exported() {
  local out status
  out=$(node --input-type=module 2>&1 <<EOF
import { pathToFileURL } from "node:url";
const watch = await import(pathToFileURL("$ROOT/.opencode/plugins/fm-primary-watch-arm.js").href);
const turn = await import(pathToFileURL("$ROOT/.opencode/plugins/fm-primary-turnend-guard.js").href);
const nudge = await import(pathToFileURL("$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js").href);
const pre = await import(pathToFileURL("$ROOT/.opencode/plugins/fm-primary-pretool-check.js").href);
const cd = await import(pathToFileURL("$ROOT/.opencode/plugins/fm-primary-cd-check.js").href);
for (const [name, mod] of Object.entries({ watch, turn, nudge })) {
  if (typeof mod.default?.setup !== "function") throw new Error(name + " missing setup");
}
if (typeof pre.default.effect !== "function") throw new Error("pretool Effect entrypoint missing");
if (typeof cd.default.effect !== "function") throw new Error("cd Effect entrypoint missing");
if (typeof watch.FmPrimaryWatchArm !== "function") throw new Error("V1 watch factory missing");
if (typeof turn.FmPrimaryTurnendGuard !== "function") throw new Error("V1 turnend factory missing");
if (typeof nudge.FmPrimarySessionstartNudge !== "function") throw new Error("V1 nudge factory missing");
if (typeof pre.FmPrimaryPretoolCheck !== "function") throw new Error("V1 pretool factory missing");
if (typeof cd.FmPrimaryCdCheck !== "function") throw new Error("V1 cd factory missing");
EOF
)
  status=$?
  expect_code 0 "$status" "dual export shape: $out"
  [ -z "$out" ] || fail "dual export check printed: $out"
  pass "OpenCode plugins keep V1 named factories beside their V2 entrypoint"
}

test_v2_command_guard_reads_complete_tool_input() {
  local out status
  out=$(node --input-type=module 2>&1 <<EOF
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL("$ROOT/.opencode/plugins/lib/fm-command-guard-v2.js").href);
const command = "cd /tmp && bin/fm-watch-arm.sh --restart &";
if (mod.commandFromTool({ tool: "shell", input: { command } }) !== command) {
  throw new Error("complete shell input was not preserved");
}
if (mod.commandFromTool({ tool: "read", input: { command } }) !== "") {
  throw new Error("non-shell tool input was classified as a command");
}
EOF
)
  status=$?
  expect_code 0 "$status" "V2 command extraction: $out"
  pass "OpenCode V2 command guards read the complete shell tool input"
}

test_v2_watch_arm_same_location_binds_only_first_session() {
  local repo out status result log
  repo="$TMP_ROOT/watch-arm-first-only"
  make_primary "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed %s\n' "${FM_STATE_OVERRIDE:-missing}" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-operational-input.sh"
  log="$TMP_ROOT/watch-arm-first.log"
  out="$TMP_ROOT/watch-arm-first.json"
  status=0
  FM_ARM_LOG="$log" drive_v2 "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      settleMs: 800,
      sessions: {
        ses_a: { id: "ses_a", location: { directory: $dir } },
        ses_b: { id: "ses_b", location: { directory: $dir } }
      },
      events: [
        { type: "session.created", data: { sessionID: "ses_a", location: { directory: $dir } } },
        { type: "session.created", data: { sessionID: "ses_b", location: { directory: $dir } } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_b" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "same-location second session should run"
  [ ! -f "$log" ] || fail "second root session at the same location armed the watcher: $(cat "$log")"
  pass "OpenCode V2 watch-arm binds only the first root session at a location"
}

test_v2_pretool_helper_error_is_not_approval() {
  local repo out status result
  guard_runtime_ready "unevaluable guard denial" || return 0
  repo="$TMP_ROOT/pretool-missing"
  make_primary "$repo"
  out="$TMP_ROOT/pretool-missing.json"
  status=0
  drive_v2_guard "$ROOT/.opencode/plugins/fm-primary-pretool-check.js" \
    "$(guard_tool_event "$repo" "$out" shell "true")" || status=$?
  expect_code 0 "$status" "missing helper should still evaluate"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.outcome == "failed" and .tag == "Tool.Error"' >/dev/null \
    || fail "missing helper was treated as approval: $result"
  pass "OpenCode V2 pretool rejects the call when the guard helper cannot be evaluated"
}

test_v2_guard_without_runtime_refuses_to_register() {
  local out status
  out=$(node --input-type=module 2>&1 <<EOF
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL("$ROOT/.opencode/plugins/lib/fm-command-guard-v2.js").href);
let registered = false;
const ctx = { location: { directory: "$TMP_ROOT" }, tool: { hook() { registered = true; } } };
try {
  mod.setupCommandGuardEffectV2(ctx, { helper: "fm-cd-pretool-check.sh", fallbackReason: "x" }, null);
} catch (error) {
  if (!String(error.message).includes("npm ci --prefix .opencode/plugins")) throw error;
  if (registered) throw new Error("a hook was registered without the runtime");
  process.exit(0);
}
throw new Error("guard setup succeeded without the effect runtime");
EOF
)
  status=$?
  expect_code 0 "$status" "guard without runtime: $out"
  pass "OpenCode V2 guard fails loudly with the install command when the effect runtime is missing"
}

test_v2_worker_worktree_is_inert_when_canonical_is_primary() {
  local repo wt log out status
  repo="$TMP_ROOT/canonical-primary"
  wt="$TMP_ROOT/canonical-worker"
  make_primary "$repo"
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$repo" worktree add -q "$wt" -b worker
  mkdir -p "$wt/bin" "$wt/state"
  : > "$wt/AGENTS.md"
  : > "$wt/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cp "$repo/bin/fm-watch-arm.sh" "$wt/bin/fm-watch-arm.sh"
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  cp "$repo/bin/fm-operational-input.sh" "$wt/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/"*.sh "$wt/bin/"*.sh
  log="$TMP_ROOT/canonical-worker.log"
  out="$TMP_ROOT/canonical-worker.json"
  status=0
  FM_ARM_LOG="$log" drive_v2 "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$(jq -nc \
    --arg dir "$wt" --arg canonical "$repo" --arg out "$out" \
    '{
      directory: $dir,
      canonical: $canonical,
      out: $out,
      settleMs: 800,
      sessions: { ses_worker: { id: "ses_worker", location: { directory: $dir } } },
      events: [
        { type: "session.created", data: { sessionID: "ses_worker", location: { directory: $dir } } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_worker" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "worker worktree setup should run"
  [ ! -f "$log" ] || fail "a worker worktree session armed the primary's watcher: $(cat "$log")"
  pass "OpenCode V2 watch-arm stays inert in a worker worktree whose project canonical is the primary"
}

test_v2_binder_releases_deleted_lead_session() {
  local repo log out status result
  repo="$TMP_ROOT/rebind-primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'armed\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-operational-input.sh"
  log="$TMP_ROOT/rebind.log"
  out="$TMP_ROOT/rebind.json"
  status=0
  FM_ARM_LOG="$log" drive_v2 "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      settleMs: 800,
      sessions: {
        ses_a: { id: "ses_a", location: { directory: $dir } },
        ses_b: { id: "ses_b", location: { directory: $dir } }
      },
      events: [
        { type: "session.created", data: { sessionID: "ses_a", location: { directory: $dir } } },
        { type: "session.deleted", data: { sessionID: "ses_a", info: { id: "ses_a" } } },
        { type: "session.created", data: { sessionID: "ses_b", location: { directory: $dir } } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_b" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "rebind after delete should run"
  result=$(cat "$out")
  [ -f "$log" ] || fail "replacement root session did not bind after the lead was deleted: $result"
  pass "OpenCode V2 binder releases a deleted lead so a replacement root session binds"
}

test_v2_turnend_double_idle_consumes_skip_once() {
  local repo out status result
  repo="$TMP_ROOT/turnend-double-idle"
  make_primary "$repo"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard-fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
cat
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-operational-input.sh"
  out="$TMP_ROOT/turnend-double-idle.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      settleMs: 800,
      sessions: { ses_lead: { id: "ses_lead", location: { directory: $dir } } },
      events: [
        { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } },
        { type: "session.execution.interrupted", data: { sessionID: "ses_lead", reason: "user" } },
        { type: "session.execution.started", data: { sessionID: "ses_lead" } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } },
        { type: "session.execution.interrupted", data: { sessionID: "ses_lead", reason: "user" } },
        { type: "session.execution.started", data: { sessionID: "ses_lead" } },
        { type: "session.execution.succeeded", data: { sessionID: "ses_lead" } },
        { type: "session.execution.interrupted", data: { sessionID: "ses_lead", reason: "user" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "double idle turnend should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.prompts | length == 2' >/dev/null \
    || fail "expected one blind-turn prompt, one skipped follow-up, then one more prompt; got $result"
  pass "OpenCode V2 turnend treats one execution terminal event per busy period as one turn end"
}

test_v2_default_export_is_struct_with_one_v1_factory() {
  local out status wt
  wt="$TMP_ROOT/v1-loader-worktree"
  mkdir -p "$wt"
  out=$(WT="$wt" node --input-type=module 2>&1 <<EOF
import { pathToFileURL } from "node:url";
const files = [
  "fm-primary-watch-arm.js",
  "fm-primary-turnend-guard.js",
  "fm-primary-sessionstart-nudge.js",
  "fm-primary-pretool-check.js",
  "fm-primary-cd-check.js",
];
const input = { client: {}, directory: process.env.WT, worktree: process.env.WT };
for (const file of files) {
  const mod = await import(pathToFileURL("$ROOT/.opencode/plugins/" + file).href);
  const def = mod.default;
  if (!def || typeof def !== "object" || typeof def === "function") throw new Error(file + ": default is not a plain struct");
  if (typeof def.id !== "string" || !def.id) throw new Error(file + ": default.id missing");
  const entry = file.includes("pretool") || file.includes("cd-check") ? "effect" : "setup";
  if (typeof def[entry] !== "function") throw new Error(file + ": default." + entry + " missing");
  if (typeof def.server !== "function") throw new Error(file + ": default.server missing");
  const factories = new Set();
  for (const [name, value] of Object.entries(mod)) {
    const factory = name === "default" ? value.server : value;
    if (typeof factory === "function") factories.add(factory);
  }
  if (factories.size !== 2) throw new Error(file + ": expected the named V1 factory plus default.server, got " + factories.size);
  const hooks = await def.server(input);
  if (!hooks || typeof hooks !== "object") throw new Error(file + ": default.server returned no V1 hooks");
}
EOF
)
  status=$?
  expect_code 0 "$status" "plugin export shape: $out"
  pass "OpenCode plugin defaults are structs with id, a V2 entrypoint, and a server wrapping the V1 factory"
}

test_v2_watch_arm_does_not_cross_own_sessions
test_v2_watch_arm_same_location_binds_only_first_session
test_v2_worker_worktree_is_inert_when_canonical_is_primary
test_v2_binder_releases_deleted_lead_session
test_v2_turnend_double_idle_consumes_skip_once
test_v2_default_export_is_struct_with_one_v1_factory
test_v2_watch_arm_cleanup_stops_children
test_v2_turnend_queues_follow_up_for_bound_session
test_v2_sessionstart_does_not_mark_failed_admission
test_v2_sessionstart_ignores_foreign_session
test_v2_cd_guard_fails_bare_cd_with_typed_tool_error
test_v2_pretool_fails_compound_backgrounded_arm_with_typed_tool_error
test_v2_pretool_helper_error_is_not_approval
test_v2_guard_without_runtime_refuses_to_register
test_v2_command_guard_reads_complete_tool_input
test_v2_named_v1_factory_still_exported
