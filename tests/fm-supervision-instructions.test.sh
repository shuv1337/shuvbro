#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"
v2_assert_test_namespace || exit 1

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
unset OPENCODE_SESSION_ID FM_V2_ACTIVATION

# make_plain_checkout <dir>: a disposable plain (non-linked) primary checkout
# carrying this tree's bin/, supervision protocols, and AGENTS.md, plus state/.
make_plain_checkout() {
  local dir=$1
  mkdir -p "$dir/docs" "$dir/state" "$dir/config"
  git init -q -b main "$dir"
  cp -R "$ROOT/bin" "$dir/bin"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  cp "$ROOT/AGENTS.md" "$dir/AGENTS.md"
  printf 'state/\nconfig/\n' > "$dir/.gitignore"
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

# The runner's own checkout may be a linked worktree with a live state/, so
# cases that expect the plain-primary OpenCode V2 block pin a plain checkout.
PLAIN_PRIMARY="$TMP_ROOT/plain-primary"
make_plain_checkout "$PLAIN_PRIMARY"

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude Stop-hook-owned supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension background wake." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1 --x-mode 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" "- X mode: active" "x-mode stanza missing"
  assert_contains "$out" "$config/x-mode.env" "x-mode stanza did not render the effective config path"
  assert_contains "$out" 'Mode: Codex foreground checkpoint.' "codex snippet missing"
  assert_not_contains "$out" "Source \`config/x-mode.env\`" "snippet kept the repo-relative x-mode config path"
  pass "renderer includes read-only, afk, and effective x-mode current-state stanzas"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "claude pre-verification repair line is not neutral"
  assert_not_contains "$out" "is broken" "claude pre-verification repair line claimed a verified mechanism failure"
  assert_not_contains "$out" "FAILED" "claude pre-verification repair line emitted a verified failure notice"
  assert_not_contains "$out" "manual background" "claude pre-verification repair line directed a manual background arm"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude pre-verification repair line directed an arm command"

  : > "$home/config/x-mode.env"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --x-mode 1 --repair-line)
  assert_contains "$out" "source '$home/config/x-mode.env' first" "x-mode repair line did not source the effective cadence config"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "x-mode codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  out=$(FM_HOME="$home" "$RENDER" --harness pi --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" "pi repair line does not direct the model to the extension-owned tool"
  assert_not_contains "$out" "extension command /fm-watch-arm-pi" "pi repair line still directs the model to the human slash command"
  out=$(FM_HOME="$home" "$RENDER" --harness omp --repair-line)
  assert_contains "$out" "omp tool fm_watch_arm_omp" "omp repair line does not direct the model to the extension-owned tool"
  assert_contains "$out" ".omp/extensions/fm-primary-turnend-guard.ts" "omp repair line does not name its own turn-end extension"
  assert_not_contains "$out" "fm_watch_arm_pi" "omp repair line must not borrow the Pi tool"
  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_cross_harness_ordinary_continuation_and_repair_matrix() {
  local ordinary out

  out=$("$RENDER" --harness pi)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" "pi ordinary-wake line does not leave continuity to the extension"
  assert_not_contains "$ordinary" "fm_watch_arm_pi" "pi ordinary-wake line incorrectly calls the recovery tool"
  out=$("$RENDER" --harness pi --repair-line)
  assert_contains "$out" "fm_watch_arm_pi" "pi recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness omp)
  assert_contains "$out" "primary harness: omp" "omp heading missing"
  assert_contains "$out" "Mode: omp (Oh My Pi) extension background wake." "omp snippet missing"
  assert_contains "$out" "the omp extension already owns watcher continuity" "omp ordinary-wake line does not leave continuity to the extension"
  assert_contains "$out" ".omp/extensions/fm-primary-omp-watch.ts" "omp snippet did not substitute its watch extension path"
  assert_not_contains "$out" "__FM_OMP_EXT__" "omp snippet left a placeholder unsubstituted"
  assert_not_contains "$out" "__FM_OMP_TURNEND_EXT__" "omp snippet left the turn-end placeholder unsubstituted"
  assert_not_contains "$out" "project trust" "omp snippet must not carry Pi's trust prerequisite"
  out=$("$RENDER" --harness omp --repair-line)
  assert_contains "$out" "fm_watch_arm_omp" "omp recovery line lost the extension-owned repair tool"

  out=$("$RENDER" --harness opencode)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "plugin already owns watcher continuity" "opencode ordinary-wake line does not leave continuity to the plugin"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "opencode ordinary-wake line incorrectly calls the recovery probe"
  out=$("$RENDER" --harness opencode --repair-line)
  assert_contains "$out" "manual recovery probe" "opencode recovery line lost its manual probe"

  out=$(FM_ROOT_OVERRIDE="$PLAIN_PRIMARY" "$RENDER" --harness opencode-v2)
  assert_contains "$out" "primary harness: opencode-v2" "opencode-v2 heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unactivated plain V2 client lacks fallback"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "automatic OpenCode V2 supervision is inactive" "unactivated plain V2 client claims ownership"
  out=$(FM_ROOT_OVERRIDE="$PLAIN_PRIMARY" "$RENDER" --harness opencode-v2 --repair-line)
  assert_contains "$out" "fm-opencode-v2-primary.sh" "unactivated V2 recovery line lost explicit launcher"

  out=$("$RENDER" --harness claude)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Stop-owned auto-arm" "claude ordinary-wake line does not leave continuity to the Stop hook"
  assert_contains "$ordinary" "bin/fm-claude-stop-autoarm.sh" "claude ordinary-wake line lost the auto-arm script name"
  assert_contains "$ordinary" "do not arm another cycle" "claude ordinary-wake line does not forbid a model re-arm"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "claude ordinary-wake line incorrectly calls the manual arm"
  out=$("$RENDER" --harness claude --repair-line)
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "claude recovery line lost its neutral automatic-recovery guidance"
  assert_not_contains "$out" "is broken" "claude recovery line claimed failure before verification"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude recovery line must not create a repeatable manual arm loop"

  out=$("$RENDER" --harness grok)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "re-arm" "grok ordinary-wake line does not tell the model to re-arm"
  assert_contains "$ordinary" "Grok tracked background task" "grok ordinary-wake line lost tracked background ownership"
  assert_contains "$ordinary" "bin/fm-watch-arm.sh" "grok ordinary-wake line lost the background arm command"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok recovery line lost its tracked background repair"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok recovery line lost the arm command"

  out=$("$RENDER" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "next foreground" "codex ordinary-wake line lost its foreground checkpoint"
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "codex ordinary-wake line lost the checkpoint command"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codex ordinary-wake line incorrectly uses a background arm"
  out=$("$RENDER" --harness codex --repair-line)
  assert_contains "$out" "foreground checkpoint" "codex recovery line lost its checkpoint repair"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex recovery line lost the checkpoint command"

  pass "renderer preserves every harness ordinary-continuation and missing-cycle repair path"
}

test_pi_signed_preserves_identity_with_pi_supervision_protocol() {
  local out ordinary
  out=$("$RENDER" --harness pi-signed)
  assert_contains "$out" "primary harness: pi-signed" \
    "pi-signed supervision normalized the visible runtime identity to pi"
  assert_contains "$out" "Mode: Pi extension background wake." \
    "pi-signed did not reuse Pi's authoritative supervision protocol"
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Pi extension already owns watcher continuity" \
    "pi-signed ordinary-wake semantics diverged from Pi"
  out=$("$RENDER" --harness pi-signed --repair-line)
  assert_contains "$out" "Pi tool fm_watch_arm_pi" \
    "pi-signed repair semantics diverged from Pi"
  pass "pi-signed keeps its identity while sharing Pi's supervision protocol"
}

test_grok_is_background_notify() {
  local out
  out=$("$RENDER" --harness grok)
  assert_contains "$out" "Mode: Grok background-notify supervision." "grok snippet missing background-notify mode"
  assert_contains "$out" "background: true" "grok snippet missing tracked background tool instruction"
  assert_contains "$out" "synthetic_reason: task_completed" "grok snippet missing auto-wake synthetic prompt detail"
  assert_contains "$out" "bin/fm-watch-arm.sh" "grok snippet missing watcher arm"
  assert_not_contains "$out" "__FM_X_MODE_ENV" "renderer leaked an x-mode path placeholder"
  assert_not_contains "$out" "foreground checkpoint" "grok snippet must not be Codex-style foreground checkpoint"
  out=$("$RENDER" --harness grok --repair-line)
  assert_contains "$out" "Grok tracked background task" "grok repair line is not background-notify shaped"
  pass "grok supervision is Claude-shaped background notify with passive Stop-hook backstop"
}

test_grok_command_sources_effective_config() {
  local home config out
  home="$TMP_ROOT/grok-home"
  config="$TMP_ROOT/grok-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness grok --x-mode 1)
  assert_contains "$out" "[ -f '$config/x-mode.env' ] && . '$config/x-mode.env'; exec bin/fm-watch-arm.sh" "grok arm command did not use the effective x-mode config path"
  pass "grok rendered command sources the effective x-mode config"
}

test_pi_snippet_uses_effective_extension_path() {
  local home out turnend watch
  home="$TMP_ROOT/pi-home"
  turnend="$ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  watch="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" "$RENDER" --harness pi)
  assert_contains "$out" "-e $turnend -e $watch" "pi snippet did not render both effective extension launch paths"
  assert_contains "$out" "The turn-end guard extension lives at \`$turnend\`" "pi snippet did not render the turn-end guard extension path"
  assert_contains "$out" "The watcher extension lives at \`$watch\`" "pi snippet did not render the watcher extension path"
  assert_contains "$out" "MAIN must not re-drain, re-run, or acknowledge it" "pi snippet lost merged-event ownership"
  assert_contains "$out" "MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a merged sailboat outcome" "pi snippet imposed a mechanical sailboat treatment"
  assert_not_contains "$out" "__FM_PI_EXT__" "renderer leaked the Pi extension path placeholder"
  assert_not_contains "$out" "__FM_PI_TURNEND_EXT__" "renderer leaked the Pi turn-end extension path placeholder"
  assert_not_contains "$out" "state/fm-primary-pi-watch.ts" "pi snippet kept the old generated state-relative extension path"
  pass "pi supervision snippet renders the effective extension path"
}

# Each checkout renders through its own copy of the real script, exactly as a
# session start in that checkout would.
test_opencode_v2_linked_checkout_reports_inactive_supervision() {
  local plain="$TMP_ROOT/v2-scope-plain" linked="$TMP_ROOT/v2-scope-linked" out ordinary
  make_plain_checkout "$plain"
  git -C "$plain" worktree add -q "$linked" -b linked-home
  mkdir -p "$linked/state" "$linked/config"
  [ "$(git -C "$linked" rev-parse --git-dir)" != "$(git -C "$linked" rev-parse --git-common-dir)" ] \
    || fail "fixture vacuous: the linked checkout is not a linked worktree"

  out=$("$plain/bin/fm-supervision-instructions.sh" --harness opencode-v2)
  assert_contains "$out" "INACTIVE" "unactivated plain primary incorrectly claims native ownership"
  assert_not_contains "$out" "plugin already owns watcher continuity" "unactivated plain primary claims plugin continuity"

  out=$("$linked/bin/fm-supervision-instructions.sh" --harness opencode-v2)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_not_contains "$out" "plugin already owns watcher continuity" "linked checkout still claims the inert plugin owns continuity"
  assert_not_contains "$out" "Mode: OpenCode V2 plugin background wake." "linked checkout still renders the plugin wake protocol"
  assert_contains "$ordinary" "automatic OpenCode V2 supervision is inactive in this checkout" "linked ordinary-wake line does not state inactivity"
  assert_contains "$out" "OpenCode V2 automatic supervision: INACTIVE in this checkout." "linked checkout lacks the inactive notice"
  assert_contains "$out" "fm-opencode-v2-primary.sh" "linked checkout lacks explicit activation instructions"
  assert_contains "$out" "Mode: Unknown harness fallback." "linked checkout lacks the unverified-wake fallback protocol"
  assert_contains "$out" "bounded foreground wait over \`bin/fm-watch.sh\`" "linked fallback lost its bounded foreground wait"

  out=$("$linked/bin/fm-supervision-instructions.sh" --harness opencode-v2 --repair-line)
  assert_not_contains "$out" "letting the OpenCode TUI plugin arm" "linked repair line defers to the inert plugin"
  assert_contains "$out" "inactive without exact activation" "linked repair line does not state inactivity"
  out=$("$plain/bin/fm-supervision-instructions.sh" --harness opencode-v2 --repair-line)
  assert_contains "$out" "inactive without exact activation" "unactivated plain repair claims plugin ownership"

  rm -rf "$linked/state"
  out=$("$linked/bin/fm-supervision-instructions.sh" --harness opencode-v2)
  assert_contains "$out" "INACTIVE" "missing state incorrectly grants activation eligibility"
  pass "opencode-v2 supervision instructions report inactive automatic supervision in a linked checkout and keep the plain primary block"
}

test_opencode_v2_secondmate_home_reports_inactive_supervision() {
  local home="$TMP_ROOT/v2-secondmate" out
  make_plain_checkout "$home"
  printf 'mate1\n' > "$home/.fm-secondmate-home"
  out=$("$home/bin/fm-supervision-instructions.sh" --harness opencode-v2)
  assert_not_contains "$out" "plugin already owns watcher continuity" "secondmate home still claims the inert plugin owns continuity"
  assert_contains "$out" "OpenCode V2 secondmates are not qualified" "secondmate home lacks the qualification reason"
  out=$("$home/bin/fm-supervision-instructions.sh" --harness opencode-v2 --repair-line)
  assert_contains "$out" "inactive in a secondmate home" "secondmate repair line does not state inactivity"
  pass "opencode-v2 supervision instructions report inactive automatic supervision in a secondmate home"
}

test_other_harnesses_render_identically_in_linked_and_plain_checkouts() {
  local plain="$TMP_ROOT/other-plain" linked="$TMP_ROOT/other-linked" harness a b
  make_plain_checkout "$plain"
  git -C "$plain" worktree add -q "$linked" -b other-linked
  mkdir -p "$linked/state" "$linked/config"
  for harness in claude codex opencode pi pi-signed grok cursor omp not-real; do
    a=$("$plain/bin/fm-supervision-instructions.sh" --harness "$harness")
    b=$("$linked/bin/fm-supervision-instructions.sh" --harness "$harness")
    assert_equals "$a" "${b//$linked/$plain}" "$harness block changed between a plain and a linked checkout"
    a=$("$plain/bin/fm-supervision-instructions.sh" --harness "$harness" --repair-line)
    b=$("$linked/bin/fm-supervision-instructions.sh" --harness "$harness" --repair-line)
    assert_equals "$a" "${b//$linked/$plain}" "$harness repair line changed between a plain and a linked checkout"
  done
  pass "every other harness renders the same block and repair line in linked and plain checkouts"
}

test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_repair_lines
test_cross_harness_ordinary_continuation_and_repair_matrix
test_pi_signed_preserves_identity_with_pi_supervision_protocol
test_grok_is_background_notify
test_grok_command_sources_effective_config
test_pi_snippet_uses_effective_extension_path
test_opencode_v2_linked_checkout_reports_inactive_supervision
test_opencode_v2_secondmate_home_reports_inactive_supervision
test_other_harnesses_render_identically_in_linked_and_plain_checkouts

test_activated_linked_external_home() {
  local plain="$TMP_ROOT/activated-plain" linked="$TMP_ROOT/activated-linked" home="$TMP_ROOT/activated-external" out
  make_plain_checkout "$plain"
  git -C "$plain" worktree add -q "$linked" -b activated-linked
  mkdir -p "$home/state" "$home/config"
  out=$(CODE="$ROOT" LEAD_ROOT="$linked" LEAD_HOME="$home" node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const owner=await import(pathToFileURL(process.env.CODE+'/bin/fm-opencode-v2-owner.mjs'));
const me=owner.identity(process.pid), root=process.env.LEAD_ROOT, home=process.env.LEAD_HOME;
const r={version:1,sessionID:'ses_render',claimID:'e'.repeat(48),root,home,state:home+'/state',config:home+'/config',ownerPID:me.pid,ownerStart:me.start,hostBootID:me.boot,servicePID:me.pid,serviceStart:me.start,serviceURL:'http://127.0.0.1:12345',lifecycle:'claimed'};
owner.publish('claim',r);
try {
 const result=spawnSync(root+'/bin/fm-supervision-instructions.sh',['--harness','opencode-v2'],{encoding:'utf8',env:{...process.env,OPENCODE_SESSION_ID:r.sessionID,FM_ROOT_OVERRIDE:root,FM_HOME:home,FM_STATE_OVERRIDE:r.state,FM_CONFIG_OVERRIDE:r.config}});
 assert.equal(result.status,0,result.stderr);
 assert.match(result.stdout,/plugin already owns watcher continuity/);
 assert.match(result.stdout,/delivers lead prompts as steers/);
 assert.doesNotMatch(result.stdout,/INACTIVE/);
 console.log('activated linked external-home lead retains native protocol');
} finally {owner.publish('retire',r);owner.publish('cleanup-test-namespace',{});}
JS
  ) || fail "activated linked/external-home renderer failed: $out"
  pass "$out"
}
test_activated_linked_external_home
