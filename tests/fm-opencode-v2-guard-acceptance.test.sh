#!/usr/bin/env bash
# Exact-session lead guard acceptance for OpenCode V2 on the shared service
# (issue #1; frozen contract "Exact guards and stale protective refusal").
#
# Only an exact registered root lead receives lead-only shell policy. A child
# (even one carrying an inherited marker), a worker or scout location, an
# unrelated root session at the same checkout, and a root session carrying a
# marker that names another session all stay outside lead-only policy. A stale
# exact registered lead keeps protective refusal until an explicit verified
# rebind, including across a server plugin reload, and an unevaluable guard for
# a registered lead denies.
#
# The protected command is the cd-guard's persistent top-level `cd projects/x`;
# the allowed command is `git -C projects/x status`. Both are classified by the
# production policy owners, never by this test.
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-guard-acceptance)
export NODE_NO_WARNINGS=1
PROTECTED='cd projects/x'
ALLOWED='git -C projects/x status'

if ! v2_guard_runtime_ready; then
  printf 'skip: the V2 guard runtime is not installed (npm ci --prefix .opencode/plugins)\n'
  exit 0
fi

guard_outcome() {  # <directory> <sessions-json> <session-id> <command> <out>
  v2_drive_guard "$(jq -nc --arg d "$1" --argjson s "$2" --argjson e "$(v2_shell_event "$3" "$4")" --arg out "$5" \
    '{directory: $d, sessions: $s, event: $e, out: $out}')" || fail "guard driver failed for $3"
  jq -e '.hooks >= 1' "$5" >/dev/null || fail "fixture vacuous: no execute.before hook registered for $1"
  jq -r '.outcome' "$5"
}

test_unrelated_root_session_at_primary_is_inert() {
  local repo sessions out
  repo="$TMP_ROOT/unrelated/primary"
  v2_make_primary "$repo"
  sessions=$(jq -nc --argjson a "$(v2_root_session ses_adhoc "$repo")" '{ses_adhoc: $a}')
  out="$TMP_ROOT/unrelated/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_adhoc "$PROTECTED" "$out")" = allowed ] \
    || fail "an unrelated root session at the primary checkout received lead-only policy: $(cat "$out")"
  pass "guard: an unrelated root session at the primary checkout stays outside lead-only policy"
}

test_child_with_inherited_marker_is_inert() {
  local repo sessions out
  repo="$TMP_ROOT/child/primary"
  v2_make_primary "$repo"
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo" ses_lead)" \
    --argjson c "$(v2_child_session ses_child ses_lead "$repo" ses_lead)" '{ses_lead: $l, ses_child: $c}')
  out="$TMP_ROOT/child/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_child "$PROTECTED" "$out")" = allowed ] \
    || fail "a child carrying its parent's inherited marker received lead-only policy: $(cat "$out")"
  pass "guard: a child session carrying an inherited lead marker stays outside lead-only policy"
}

test_root_with_foreign_marker_is_inert() {
  local repo sessions out
  repo="$TMP_ROOT/foreign-marker/primary"
  v2_make_primary "$repo"
  sessions=$(jq -nc --argjson f "$(v2_root_session ses_fork "$repo" ses_lead)" '{ses_fork: $f}')
  out="$TMP_ROOT/foreign-marker/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_fork "$PROTECTED" "$out")" = allowed ] \
    || fail "a root session whose marker names another session received lead-only policy: $(cat "$out")"
  pass "guard: a root session carrying another session's marker stays outside lead-only policy"
}

test_worker_location_is_inert() {
  local repo wt sessions out
  repo="$TMP_ROOT/worker/primary"
  wt="$TMP_ROOT/worker/task"
  v2_make_primary "$repo"
  v2_make_worktree "$repo" "$wt"
  sessions=$(jq -nc --argjson w "$(v2_root_session ses_worker "$wt")" '{ses_worker: $w}')
  out="$TMP_ROOT/worker/out.json"
  [ "$(guard_outcome "$wt" "$sessions" ses_worker "$PROTECTED" "$out")" = allowed ] \
    || fail "a worker task location received lead-only policy: $(cat "$out")"
  pass "guard: a worker task location stays outside lead-only policy"
}

# An exact marker on a root session with no valid registration is a stale or
# unverifiable registered lead: protective refusal, not approval.
test_exact_marker_without_registration_refuses_protected() {
  local repo sessions out
  repo="$TMP_ROOT/marker-only/primary"
  v2_make_primary "$repo"
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo" ses_lead)" '{ses_lead: $l}')
  out="$TMP_ROOT/marker-only/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$PROTECTED" "$out")" = failed ] \
    || fail "an exact-marked lead with no valid registration was allowed a protected command: $(cat "$out")"
  jq -e '.messages | map(length > 0) | all' "$out" >/dev/null || fail "protective refusal carried no diagnostic: $(cat "$out")"
  # A fresh entry instance (server plugin reload) has no memory; refusal must hold.
  out="$TMP_ROOT/marker-only/reload.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$PROTECTED" "$out")" = failed ] \
    || fail "protective refusal did not survive a server plugin reload: $(cat "$out")"
  pass "guard: an exact-marked lead without a valid registration refuses protected commands, across reload"
}

# The divergence pair that keeps the marker-only case honest: the same
# protected command at the same checkout is refused only for the marked lead.
test_marker_divergence_is_exact() {
  local repo sessions lead adhoc
  repo="$TMP_ROOT/divergence/primary"
  v2_make_primary "$repo"
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo" ses_lead)" \
    --argjson a "$(v2_root_session ses_adhoc "$repo")" '{ses_lead: $l, ses_adhoc: $a}')
  lead=$(guard_outcome "$repo" "$sessions" ses_lead "$PROTECTED" "$TMP_ROOT/divergence/lead.json")
  adhoc=$(guard_outcome "$repo" "$sessions" ses_adhoc "$PROTECTED" "$TMP_ROOT/divergence/adhoc.json")
  [ "$lead" = failed ] && [ "$adhoc" = allowed ] \
    || fail "guard scope is not exact-session (lead=$lead adhoc=$adhoc)"
  pass "guard: the same protected command diverges exactly between the marked lead and an unrelated root"
}

test_valid_registered_lead_keeps_classifier_cases() {
  local repo sessions out ns=v2guard$$
  repo="$TMP_ROOT/registered/primary"
  v2_make_primary "$repo"
  v2_register_lead registered-lead "$ns" ses_lead "$repo" "$repo" "$repo/state" "$repo/config" "$$" || return $?
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo" ses_lead)" '{ses_lead: $l}')
  out="$TMP_ROOT/registered/deny.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$PROTECTED" "$out")" = failed ] \
    || fail "a valid registered lead was allowed a protected command: $(cat "$out")"
  out="$TMP_ROOT/registered/allow.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$ALLOWED" "$out")" = allowed ] \
    || fail "a valid registered lead was refused a classifier-allowed command: $(cat "$out")"
  pass "guard: a valid registered lead keeps the classifiers' deny and allow cases"
}

test_registry_protects_when_marker_removed() {
  local repo sessions out ns=v2guardrm$$
  repo="$TMP_ROOT/marker-removed/primary"
  v2_make_primary "$repo"
  v2_register_lead marker-removed "$ns" ses_lead "$repo" "$repo" "$repo/state" "$repo/config" "$$" || return $?
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo")" '{ses_lead: $l}')
  out="$TMP_ROOT/marker-removed/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$PROTECTED" "$out")" = failed ] \
    || fail "removing the native marker erased registry protection for the registered lead: $(cat "$out")"
  pass "guard: a fixed registry record keeps protecting the exact lead after its native marker is removed"
}

test_retired_lead_refuses_until_rebind() {
  local repo sessions out ns=v2guardret$$
  repo="$TMP_ROOT/retired/primary"
  v2_make_primary "$repo"
  v2_register_lead retired-lead "$ns" ses_lead "$repo" "$repo" "$repo/state" "$repo/config" "$$" || return $?
  v2_retire_lead retired-lead "$ns" ses_lead || return $?
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo" ses_lead)" '{ses_lead: $l}')
  out="$TMP_ROOT/retired/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$PROTECTED" "$out")" = failed ] \
    || fail "a retired registered lead was allowed a protected command before rebind: $(cat "$out")"
  pass "guard: a retired registered lead keeps protective refusal until explicit rebind"
}

test_unevaluable_guard_denies_registered_lead() {
  local repo sessions out ns=v2guardfail$$
  repo="$TMP_ROOT/unevaluable/primary"
  v2_make_primary "$repo"
  v2_register_lead unevaluable "$ns" ses_lead "$repo" "$repo" "$repo/state" "$repo/config" "$$" || return $?
  rm -f "$repo/bin/fm-cd-command-policy.mjs" "$repo/bin/fm-arm-command-policy.mjs"
  sessions=$(jq -nc --argjson l "$(v2_root_session ses_lead "$repo" ses_lead)" '{ses_lead: $l}')
  out="$TMP_ROOT/unevaluable/out.json"
  [ "$(guard_outcome "$repo" "$sessions" ses_lead "$ALLOWED" "$out")" = failed ] \
    || fail "a registered lead whose guard policy is missing was implicitly approved: $(cat "$out")"
  pass "guard: an unevaluable guard denies the registered lead instead of approving"
}

v2_run_cases \
  test_unrelated_root_session_at_primary_is_inert \
  test_child_with_inherited_marker_is_inert \
  test_root_with_foreign_marker_is_inert \
  test_worker_location_is_inert \
  test_exact_marker_without_registration_refuses_protected \
  test_marker_divergence_is_exact \
  test_valid_registered_lead_keeps_classifier_cases \
  test_registry_protects_when_marker_removed \
  test_retired_lead_refuses_until_rebind \
  test_unevaluable_guard_denies_registered_lead
