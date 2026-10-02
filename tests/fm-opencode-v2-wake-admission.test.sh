#!/usr/bin/env bash
# Wake handoff and admission sequencing for the OpenCode V2 adapter, against the
# real recovery helpers.
#
# Part 1 pins the helper contract the adapter must respect: the handling
# handoff (`fm-watch-arm.sh --handling-delivered`) is accepted while the
# episode is still open, and rejected once the lead has drained and
# acknowledged it. A confirmation issued after prompt admission therefore races
# the lead's own acknowledgement, most visibly when an admission acknowledgement
# is lost and retried after backoff.
#
# Part 2 drives the production V2 watch-arm plugin entry against a real
# bin/fm-watch-arm.sh + bin/fm-watch.sh in a disposable primary, with only the
# native session.prompt admission faked. It asserts outcomes, not ordering
# internals: one admitted logical wake per event across rejected admissions and
# lost acknowledgements, the episode left in handling, durable rows kept until
# the lead acknowledges, one live watcher, and no stranded wake after an
# admission outage longer than any retry budget.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-wake-admission)
export NODE_NO_WARNINGS=1
ARM_PID=

# The lead's handling turn: drain, then the generation-bound acknowledgement.
lead_drain_and_ack() {  # <state>
  local state=$1
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$state/.lead-drain.out" 2> "$state/.lead-drain.err" || return 1
  ack_drain_err "$state" "$state/.lead-drain.err"
}

start_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i=0
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  while [ "$i" -lt 100 ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
}

# Real first cycle delivers one signal wake; then a handling successor starts.
# Sets EP_GENERATION and EP_WATCHER for the successor; ARM_PID is its arm.
EP_GENERATION=
EP_WATCHER=
open_handling_episode() {  # <dir>
  local dir=$1 home=$1/home state=$1/state fakebin=$1/fakebin first generation pid
  mkdir -p "$home/data"
  start_arm "$home" "$state" "$fakebin" "$dir/first.out"
  first=$ARM_PID
  printf 'done: alpha finished\n' > "$state/alpha.status"
  wait_for_exit "$first" 120 >/dev/null || fail "fixture watcher did not deliver its wake"
  grep -q '^signal:' "$dir/first.out" || fail "first cycle did not report its wake: $(cat "$dir/first.out")"
  start_arm "$home" "$state" "$fakebin" "$dir/successor.out" "$first"
  generation=$(sed -n 's/^watcher: started pid=[0-9]*.* recovery-generation=\([A-Za-z0-9._-]*\)$/\1/p' "$dir/successor.out")
  pid=$(sed -n 's/^watcher: started pid=\([0-9]*\).* recovery-generation=.*$/\1/p' "$dir/successor.out")
  [ -n "$generation" ] && [ -n "$pid" ] || fail "handling successor did not report a recovery generation: $(cat "$dir/successor.out")"
  EP_GENERATION=$generation
  EP_WATCHER=$pid
}

test_handoff_before_lead_ack_is_accepted() {
  local dir state generation pid
  dir=$(make_case handoff-before-ack)
  state="$dir/state"
  open_handling_episode "$dir"
  generation=$EP_GENERATION
  pid=$EP_WATCHER
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" --watcher-pid "$pid" \
    || fail "handoff confirmation was rejected while the episode was open"
  lead_drain_and_ack "$state" || fail "lead acknowledgement after an accepted handoff failed"
  case "$(cat "$state/.watcher-down")" in acked:*:"$generation") ;; *) fail "episode not retired: $(cat "$state/.watcher-down")" ;; esac
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged wake stayed queued"
  kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
  pass "helper contract: handoff confirmed before the lead acknowledges is accepted and the episode retires"
}

test_handoff_after_lead_ack_is_rejected() {
  local dir state generation pid status=0
  dir=$(make_case handoff-after-ack)
  state="$dir/state"
  open_handling_episode "$dir"
  generation=$EP_GENERATION
  pid=$EP_WATCHER
  # The lead received the wake (admission succeeded), drained and acknowledged
  # it before the adapter's late confirmation ran.
  lead_drain_and_ack "$state" || fail "lead acknowledgement failed"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$generation" --watcher-pid "$pid" \
    || status=$?
  [ "$status" -ne 0 ] || fail "a handoff confirmed after the lead acknowledged the episode was accepted"
  is_live_non_zombie "$ARM_PID" || fail "the live successor did not survive the rejected late handoff"
  kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
  pass "helper contract: a handoff confirmed after the lead acknowledged is rejected, so confirmation must precede admission"
}

# --- Part 2: production V2 watch-arm entry against the real helpers ---------

make_primary_copy() {  # <dir>
  local root=$1
  mkdir -p "$root/state" "$root/config" "$root/data" "$root/.opencode"
  git init -q "$root"
  cp -R "$ROOT/bin" "$root/bin"
  cp "$ROOT/AGENTS.md" "$root/AGENTS.md"
  cp -R "$ROOT/.opencode/plugins" "$root/.opencode/plugins"
  rm -rf "$root/.opencode/plugins/node_modules"
  : > "$root/config/x-mode.env"
}

# spec: rejectCount | lostAckCount | outageMs. The driver binds and idles the
# lead, waits for the plugin-owned watcher, writes one status change, lets the
# adapter run, and records admissions plus helper state before cleanup.
drive_admission() {  # <root> <fakebin> <out> <spec-json>
  local root=$1 fakebin=$2 out=$3 spec=$4 driver status=0
  PATH="$fakebin:$PATH" FM_HOME="$root" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_CONFIG_OVERRIDE="$root/config" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    node --input-type=module - "$root" "$out" "$spec" <<'EOF' &
import { pathToFileURL } from "node:url";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const [root, out, specText] = process.argv.slice(2);
const spec = JSON.parse(specText);
const state = `${root}/state`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const read = (file) => { try { return readFileSync(file, "utf8"); } catch { return ""; } };
const alive = (pid) => { try { process.kill(Number(pid), 0); return true; } catch { return false; } };

const attempts = [];
const admitted = [];
const ids = new Set();
let rejects = spec.rejectCount || 0;
let lostAcks = spec.lostAckCount || 0;
let outageUntil = 0;
const queue = [];
let notify = null;
const ctx = {
  location: { directory: root, project: { directory: root, canonical: root, id: "proj" } },
  event: {
    subscribe({ signal } = {}) {
      return {
        async *[Symbol.asyncIterator]() {
          while (!signal?.aborted) {
            if (queue.length) { yield queue.shift(); continue; }
            await new Promise((resolve) => { notify = resolve; signal?.addEventListener("abort", resolve, { once: true }); });
          }
        },
      };
    },
  },
  session: {
    async get({ sessionID }) {
      if (sessionID !== "ses_lead") throw new Error("missing session");
      return { id: "ses_lead", location: { directory: root } };
    },
    async prompt(request) {
      const at = Date.now();
      attempts.push({ ...request, at });
      if (at < outageUntil) throw new Error("admission outage");
      if (rejects > 0) { rejects -= 1; throw new Error("admission rejected"); }
      if (!(request.id && ids.has(request.id))) {
        admitted.push({ ...request, at });
        if (request.id) ids.add(request.id);
      }
      if (lostAcks > 0) { lostAcks -= 1; throw new Error("acknowledgement lost"); }
      return { id: request.id || `msg_${attempts.length}` };
    },
  },
};
const push = (event) => { queue.push(event); notify?.(); };

const mod = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-watch-arm.js`).href);
const cleanup = await mod.default.setup(ctx);
await sleep(50);
push({ type: "session.execution.succeeded", data: { sessionID: "ses_lead" } });

let watcher = "";
for (let i = 0; i < 200 && !watcher; i += 1) {
  const pid = read(`${state}/.watch.lock/pid`).trim();
  if (pid && alive(pid) && existsSync(`${state}/.last-watcher-beat`)) watcher = pid;
  else await sleep(50);
}
if (!watcher) throw new Error("plugin-owned watcher never started");
if (spec.outageMs) outageUntil = Date.now() + spec.outageMs;
const changedAt = Date.now();
writeFileSync(`${state}/alpha.status`, "done: alpha finished\n");
await sleep(spec.settleMs || 6000);

const watcherPid = read(`${state}/.watch.lock/pid`).trim();
const result = {
  changedAt,
  outageEnd: outageUntil,
  attempts,
  admitted,
  marker: read(`${state}/.watcher-down`).trim(),
  queue: read(`${state}/.wake-queue`),
  watcherLive: Boolean(watcherPid) && alive(watcherPid),
};
if (typeof cleanup === "function") await cleanup();
result.markerAfterCleanup = read(`${state}/.watcher-down`).trim();
const lockAfter = read(`${state}/.watch.lock/pid`).trim();
result.watcherLiveAfterCleanup = Boolean(lockAfter) && alive(lockAfter);
writeFileSync(out, JSON.stringify(result));
process.exit(0);
EOF
  driver=$!
  printf '%s' "$driver" > "$root/state/.lock"
  wait "$driver" || status=$?
  expect_code 0 "$status" "admission driver"
  [ -s "$out" ] || fail "admission driver wrote no result"
  jq -e '.attempts | length >= 1' "$out" >/dev/null \
    || fail "fixture vacuous: the real watcher wake never reached prompt admission: $(cat "$out")"
}

admission_case() {  # <name> <spec-json>
  local dir
  dir=$(make_case "$1")
  make_primary_copy "$dir/root"
  drive_admission "$dir/root" "$dir/fakebin" "$dir/out.json" "$2"
  RESULT_FILE="$dir/out.json"
}

wake_admissions() {  # jq filter over admitted wake prompts for the lead
  jq '[.admitted[] | select(.sessionID == "ses_lead" and (.text | test("alpha|signal:")))]' "$RESULT_FILE"
}

assert_open_handling_and_durable_row() {  # <label>
  jq -e '.marker | test("^(pending|announced):handling:")' "$RESULT_FILE" >/dev/null \
    || fail "$1: the episode was not left in handling for the lead: $(jq -c '.marker' "$RESULT_FILE")"
  jq -e '.queue | test("alpha")' "$RESULT_FILE" >/dev/null \
    || fail "$1: the durable wake row was consumed before the lead acknowledged it"
  jq -e '.watcherLive' "$RESULT_FILE" >/dev/null || fail "$1: no live watcher after delivery"
}

test_baseline_admission_delivers_one_wake() {
  admission_case admission-baseline '{"settleMs": 5000}'
  [ "$(wake_admissions | jq length)" = 1 ] || fail "baseline: expected one admitted wake: $(cat "$RESULT_FILE")"
  assert_open_handling_and_durable_row baseline
  pass "V2 adapter + real helpers: one status change admits one queued wake with the episode in handling"
}

test_rejected_admissions_retry_with_one_id() {
  admission_case admission-rejected '{"rejectCount": 2, "settleMs": 9000}'
  [ "$(wake_admissions | jq length)" = 1 ] \
    || fail "rejected admissions: expected exactly one admitted wake after retries: $(cat "$RESULT_FILE")"
  jq -e '[.attempts[] | select(.sessionID == "ses_lead" and (.text | test("alpha|signal:"))) | .id]
         | length >= 3 and all(type == "string" and startswith("msg_")) and (unique | length == 1)' "$RESULT_FILE" >/dev/null \
    || fail "rejected admissions: every retry of one wake must reuse one msg_ id: $(jq -c '.attempts' "$RESULT_FILE")"
  assert_open_handling_and_durable_row "rejected admissions"
  pass "V2 adapter + real helpers: rejected admissions retry with one stable id and admit one wake"
}

test_lost_ack_after_admission_is_not_a_failure() {
  admission_case admission-lost-ack '{"lostAckCount": 1, "settleMs": 9000}'
  [ "$(wake_admissions | jq length)" = 1 ] \
    || fail "lost acknowledgement: expected exactly one admitted wake: $(cat "$RESULT_FILE")"
  jq -e '[.admitted[] | select(.text | test("FAILED"))] | length == 0' "$RESULT_FILE" >/dev/null \
    || fail "lost acknowledgement: an admitted wake was reported to the lead as a failure: $(jq -c '.admitted' "$RESULT_FILE")"
  assert_open_handling_and_durable_row "lost acknowledgement"
  pass "V2 adapter + real helpers: a lost acknowledgement after admission yields one wake and no failure report"
}

test_admission_outage_never_strands_the_wake() {
  admission_case admission-outage '{"outageMs": 8000, "settleMs": 16000}'
  local after
  after=$(jq '[.admitted[] | select(.sessionID == "ses_lead" and .at >= $end)] | length' --argjson end "$(jq .outageEnd "$RESULT_FILE")" "$RESULT_FILE")
  [ "$after" = 1 ] \
    || fail "admission outage: after admission recovered the lead must receive exactly one prompt leading to the durable wake, got $after: $(jq -c '.admitted' "$RESULT_FILE")"
  jq -e '.queue | test("alpha")' "$RESULT_FILE" >/dev/null \
    || fail "admission outage: the durable wake row was lost"
  jq -e '.watcherLive' "$RESULT_FILE" >/dev/null || fail "admission outage: no live watcher at the end"
  pass "V2 adapter + real helpers: an admission outage longer than the retry budget does not strand the wake"
}

# The owner retires (TUI exit or plugin unload) while its wake is still
# unadmitted. The existing helper contract must leave the episode recoverable:
# the retired watcher republishes downtime and the next ordinary arm re-presents
# the still-durable row once.
test_owner_retirement_with_unadmitted_wake_is_recoverable() {
  local dir root
  dir=$(make_case admission-owner-retired)
  root="$dir/root"
  make_primary_copy "$root"
  drive_admission "$root" "$dir/fakebin" "$dir/out.json" '{"outageMs": 600000, "settleMs": 4000}'
  RESULT_FILE="$dir/out.json"
  [ "$(jq '.admitted | length' "$RESULT_FILE")" = 0 ] || fail "fixture vacuous: a prompt was admitted during the outage"
  local i=0
  while [ "$i" -lt 50 ]; do
    case "$(cat "$root/state/.watcher-down" 2>/dev/null)" in pending:downtime:*|announced:downtime:*) break ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  case "$(cat "$root/state/.watcher-down" 2>/dev/null)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "owner retirement left the unadmitted episode as handled: $(cat "$root/state/.watcher-down" 2>/dev/null)" ;;
  esac
  grep -q alpha "$root/state/.wake-queue" || fail "owner retirement consumed the unadmitted durable row"
  start_arm "$root" "$root/state" "$dir/fakebin" "$dir/next-owner.out"
  wait_for_exit "$ARM_PID" 80 >/dev/null || fail "the next ordinary arm did not re-present the unadmitted wake"
  grep -qF 'check: rearm-resurface' "$dir/next-owner.out" \
    || fail "the next ordinary arm did not emit the recovery wake: $(cat "$dir/next-owner.out")"
  jq -e '(.watcherLiveAfterCleanup | not) and (.markerAfterCleanup | test(":downtime:"))' "$RESULT_FILE" >/dev/null \
    || fail "owner cleanup resolved before its watcher retired and republished downtime (bounded retirement not awaited): $(jq -c '{markerAfterCleanup, watcherLiveAfterCleanup}' "$RESULT_FILE")"
  pass "V2 adapter + real helpers: owner retirement with an unadmitted wake leaves it recoverable by the next arm"
}

FAILED=0
for t in \
  test_owner_retirement_with_unadmitted_wake_is_recoverable \
  test_handoff_before_lead_ack_is_accepted \
  test_handoff_after_lead_ack_is_rejected \
  test_baseline_admission_delivers_one_wake \
  test_rejected_admissions_retry_with_one_id \
  test_lost_ack_after_admission_is_not_a_failure \
  test_admission_outage_never_strands_the_wake; do
  ( "$t" ) || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] || { printf 'not ok - %s wake admission case(s) failed\n' "$FAILED" >&2; exit 1; }
