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
const toolHooks = [];
const shellHooks = [];
const permissionHooks = [];
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
  tool: {
    async hook(name, callback) {
      toolHooks.push({ name, callback });
    },
  },
  shell: {
    async hook(name, callback) {
      shellHooks.push({ name, callback });
    },
  },
  permission: {
    async hook(name, callback) {
      permissionHooks.push({ name, callback });
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
if (spec.toolEvent) {
  const hook = toolHooks.find((item) => item.name === "execute.before");
  if (!hook) throw new Error("missing tool.execute.before");
  try {
    await hook.callback(spec.toolEvent);
    writeFileSync(spec.out, JSON.stringify({ prompts, tool: "ran", denied: false, toolHooks: toolHooks.map((h) => h.name), shellHooks: shellHooks.map((h) => h.name) }));
  } catch (error) {
    writeFileSync(spec.out, JSON.stringify({ prompts, tool: "threw", denied: true, reason: String(error.message || error), toolHooks: toolHooks.map((h) => h.name), shellHooks: shellHooks.map((h) => h.name) }));
  }
} else if (spec.permissionEvent) {
  const hook = permissionHooks.find((item) => item.name === "evaluate");
  if (!hook) throw new Error("missing permission.evaluate");
  const event = spec.permissionEvent;
  await hook.callback(event);
  writeFileSync(spec.out, JSON.stringify({ prompts, effect: event.effect, message: event.message || "" }));
} else {
  if (spec.cleanup) {
    if (typeof cleanup !== "function") throw new Error("setup did not return cleanup");
    cleanup();
  }
  writeFileSync(spec.out, JSON.stringify({ prompts, cleaned: Boolean(spec.cleanup) }));
}
abort.abort();
notify?.();
EOF
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
        { type: "session.status", data: { sessionID: "ses_other", status: { type: "idle" } } }
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
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "idle" } } }
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
      events: [ { type: "session.idle", data: { sessionID: "ses_lead" } } ]
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
        { type: "session.status", data: { sessionID: "ses_other", status: { type: "idle" } } },
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "idle" } } }
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
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "idle" } } }
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

test_v2_pretool_reads_tool_input_not_output_args() {
  local repo out status result
  repo="$TMP_ROOT/pretool-primary"
  make_primary "$repo"
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'denied-by-seatbelt\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-arm-pretool-check.sh"
  out="$TMP_ROOT/pretool-out.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-pretool-check.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      toolEvent: {
        tool: "shell",
        sessionID: "ses_lead",
        agent: "build",
        messageID: "msg_1",
        id: "call_1",
        input: { command: "bin/fm-watch-arm.sh --restart &" }
      }
    }')" || status=$?
  expect_code 0 "$status" "V2 pretool setup should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.denied == true' >/dev/null \
    || fail "tool.execute.before did not deny from input.command: $result"
  printf '%s' "$result" | jq -e '.shellHooks | index("create.before")' >/dev/null \
    || fail "shell.create.before was not registered: $result"
  pass "OpenCode V2 pretool reads tool input and registers shell.create.before"
}

test_v2_pretool_permission_deny() {
  local repo out status result
  repo="$TMP_ROOT/pretool-perm"
  make_primary "$repo"
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
printf 'denied-by-seatbelt\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-arm-pretool-check.sh"
  out="$TMP_ROOT/pretool-perm.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-pretool-check.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      permissionEvent: {
        sessionID: "ses_lead",
        action: "shell",
        resources: ["bin/fm-watch-arm.sh --restart &"],
        effect: "ask"
      }
    }')" || status=$?
  expect_code 0 "$status" "V2 permission deny should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.effect == "deny"' >/dev/null \
    || fail "permission.evaluate did not deny: $result"
  pass "OpenCode V2 pretool denies through permission.evaluate"
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
for (const [name, mod] of Object.entries({ watch, turn, nudge, pre, cd })) {
  if (typeof mod.default?.setup !== "function") throw new Error(name + " missing setup");
}
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
  pass "OpenCode plugins keep V1 named factories beside V2 setup"
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
        { type: "session.status", data: { sessionID: "ses_b", status: { type: "idle" } } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "same-location second session should run"
  [ ! -f "$log" ] || fail "second root session at the same location armed the watcher: $(cat "$log")"
  pass "OpenCode V2 watch-arm binds only the first root session at a location"
}

test_v2_pretool_helper_error_is_not_approval() {
  local repo out status result
  repo="$TMP_ROOT/pretool-missing"
  make_primary "$repo"
  out="$TMP_ROOT/pretool-missing.json"
  status=0
  drive_v2 "$ROOT/.opencode/plugins/fm-primary-pretool-check.js" "$(jq -nc \
    --arg dir "$repo" --arg out "$out" \
    '{
      directory: $dir,
      out: $out,
      toolEvent: { tool: "shell", input: { command: "true" } }
    }')" || status=$?
  expect_code 0 "$status" "missing helper should still return from setup"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.denied == true' >/dev/null \
    || fail "missing helper was treated as approval: $result"
  pass "OpenCode V2 pretool denies when the guard helper cannot be evaluated"
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
        { type: "session.status", data: { sessionID: "ses_worker", status: { type: "idle" } } }
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
        { type: "session.status", data: { sessionID: "ses_b", status: { type: "idle" } } }
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
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "idle" } } },
        { type: "session.idle", data: { sessionID: "ses_lead" } },
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "busy" } } },
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "idle" } } },
        { type: "session.idle", data: { sessionID: "ses_lead" } },
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "busy" } } },
        { type: "session.status", data: { sessionID: "ses_lead", status: { type: "idle" } } },
        { type: "session.idle", data: { sessionID: "ses_lead" } }
      ]
    }')" || status=$?
  expect_code 0 "$status" "double idle turnend should run"
  result=$(cat "$out")
  printf '%s' "$result" | jq -e '.prompts | length == 2' >/dev/null \
    || fail "expected one blind-turn prompt, one skipped follow-up, then one more prompt; got $result"
  pass "OpenCode V2 turnend treats session.status idle plus session.idle as one turn end"
}

test_v2_default_export_loads_as_v1_factory() {
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
  const seen = new Set();
  let hooks = 0;
  for (const [, fn] of Object.entries(mod)) {
    if (seen.has(fn)) continue;
    seen.add(fn);
    const init = await fn(input);
    if (!init || typeof init !== "object") throw new Error(file + ": V1 factory returned no hooks");
    hooks += 1;
  }
  if (hooks !== 1) throw new Error(file + ": V1 loader initialized " + hooks + " factories, expected 1");
  if (typeof mod.default.setup !== "function") throw new Error(file + ": default lost V2 setup");
}
EOF
)
  status=$?
  expect_code 0 "$status" "V1 loader shape over the default export: $out"
  pass "OpenCode plugin default exports stay callable V1 factories that carry V2 setup"
}

test_v2_watch_arm_does_not_cross_own_sessions
test_v2_watch_arm_same_location_binds_only_first_session
test_v2_worker_worktree_is_inert_when_canonical_is_primary
test_v2_binder_releases_deleted_lead_session
test_v2_turnend_double_idle_consumes_skip_once
test_v2_default_export_loads_as_v1_factory
test_v2_watch_arm_cleanup_stops_children
test_v2_turnend_queues_follow_up_for_bound_session
test_v2_sessionstart_does_not_mark_failed_admission
test_v2_sessionstart_ignores_foreign_session
test_v2_pretool_reads_tool_input_not_output_args
test_v2_pretool_permission_deny
test_v2_pretool_helper_error_is_not_approval
test_v2_named_v1_factory_still_exported
