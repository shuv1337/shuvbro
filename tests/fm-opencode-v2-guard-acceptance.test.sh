#!/usr/bin/env bash
# Exact-session lead guard acceptance for OpenCode V2 on the shared service
# (issue #1; frozen contract "Exact guards and stale protective refusal").
#
# The production server entry's guard runs inside a service stand-in whose pid
# is the registered execution service, against real registrations published by
# a live owner stand-in through the owner library, in a disposable registry
# namespace. Every "stays outside lead policy" case is paired with the live
# positive control (the registered lead's protected command is refused by the
# classifier), so an inert plugin cannot pass.
#
# Outcomes are classified by reason, never by "something failed":
#   classifier:<code>  the production classifier denied ([persistent-cd], ...)
#   scope              protective refusal naming an explicit rebind
#   evaluate           the guard could not evaluate (timeout, crash, bad verdict)
#   allow              no lead policy applied
set -u

# shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-opencode-v2-acceptance-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-guard-acceptance)
export NODE_NO_WARNINGS=1
PROTECTED='cd projects/x'
ALLOWED='git -C projects/x status'

# A registered lead at a guard root; sets CASE, LEAD_ROOT, HOME_DIR, V2_CLAIM.
registered_lead() {  # <case> [root]
  CASE="$TMP_ROOT/$1"
  v2_namespace "$1"
  LEAD_ROOT=${2:-$(v2_make_guard_root "$CASE/root")}
  HOME_DIR=$(v2_make_home "$CASE/home")
  v2_start_service "$CASE"
  v2_session "$CASE" ses_lead "$LEAD_ROOT"
  v2_register "$CASE" ses_lead "$LEAD_ROOT" "$HOME_DIR"
  v2_session "$CASE" ses_lead "$LEAD_ROOT" "" ses_lead "$V2_CLAIM"
}

# The live positive control every inert case depends on.
positive_control() {
  v2_expect_kind "positive control (registered lead protected command)" "classifier:persistent-cd" "$(v2_guard ses_lead "$PROTECTED")"
}

test_registered_lead_keeps_classifier_cases() {
  v2_require_native registered-lead || return $?
  registered_lead registered
  positive_control
  v2_expect_kind "registered lead allowed command" allow "$(v2_guard ses_lead "$ALLOWED")"
  pass "guard: a registered lead gets the classifier's deny code and its allowed case"
}

test_unrelated_root_session_is_inert() {
  v2_require_native unrelated-root || return $?
  registered_lead unrelated
  positive_control
  v2_session "$CASE" ses_adhoc "$LEAD_ROOT"
  v2_expect_kind "unrelated root at the lead checkout" allow "$(v2_guard ses_adhoc "$PROTECTED")"
  pass "guard: an unrelated root session at the lead's checkout stays outside lead policy"
}

test_child_with_inherited_marker_is_inert() {
  v2_require_native inherited-marker || return $?
  registered_lead child
  positive_control
  v2_session "$CASE" ses_child "$LEAD_ROOT" ses_lead ses_lead "$V2_CLAIM"
  v2_expect_kind "child with inherited marker" allow "$(v2_guard ses_child "$PROTECTED")"
  pass "guard: a child carrying the lead's inherited marker stays outside lead policy"
}

test_root_with_foreign_marker_is_inert() {
  v2_require_native foreign-marker || return $?
  registered_lead foreign
  positive_control
  v2_session "$CASE" ses_fork "$LEAD_ROOT" "" ses_lead "$V2_CLAIM"
  v2_expect_kind "root carrying another session's marker" allow "$(v2_guard ses_fork "$PROTECTED")"
  pass "guard: a root session carrying another session's marker stays outside lead policy"
}

test_worker_location_is_inert() {
  v2_require_native worker-location || return $?
  registered_lead worker
  positive_control
  local wt
  wt=$(v2_make_linked_root "$LEAD_ROOT" "$CASE/task")
  v2_session "$CASE" ses_worker "$wt"
  v2_expect_kind "worker task location" allow "$(v2_guard ses_worker "$PROTECTED")"
  pass "guard: a worker task session stays outside lead policy"
}

test_non_shell_tool_is_not_guarded() {
  v2_require_native non-shell || return $?
  registered_lead nonshell
  positive_control
  v2_expect_kind "lead edit tool" allow "$(v2_guard ses_lead "$PROTECTED" edit)"
  pass "guard: a non-shell tool of the registered lead is not subject to the shell guards"
}

test_exact_marker_without_record_refuses() {
  v2_require_native marker-only || return $?
  CASE="$TMP_ROOT/marker-only"
  v2_namespace marker-only
  local root
  root=$(v2_make_guard_root "$CASE/root")
  v2_start_service "$CASE"
  v2_session "$CASE" ses_lead "$root" "" ses_lead "$(printf 'a%.0s' $(seq 1 48))"
  v2_session "$CASE" ses_adhoc "$root"
  v2_expect_kind "marker without record" scope "$(v2_guard ses_lead "$PROTECTED")"
  v2_expect_kind "divergence: unmarked root, same checkout" allow "$(v2_guard ses_adhoc "$PROTECTED")"
  pass "guard: an exact marker without a record refuses with a rebind diagnostic, an unmarked root stays inert"
}

test_record_protects_when_marker_removed() {
  v2_require_native marker-removed || return $?
  registered_lead marker-removed
  positive_control
  v2_session "$CASE" ses_lead "$LEAD_ROOT"
  v2_expect_kind "registered lead with marker removed" "scope|classifier:persistent-cd" "$(v2_guard ses_lead "$PROTECTED")"
  pass "guard: removing the native marker does not erase registry protection"
}

test_retired_lead_refuses_until_rebind() {
  v2_require_native retired || return $?
  registered_lead retired
  positive_control
  v2_retire "$CASE" ses_lead
  v2_expect_kind "retired registered lead" scope "$(v2_guard ses_lead "$PROTECTED")"
  pass "guard: a retired registered lead keeps protective refusal until explicit rebind"
}

test_stale_service_refuses() {
  v2_require_native stale-service || return $?
  registered_lead stale-service
  positive_control
  v2_start_service "$CASE"   # a new execution service incarnation
  v2_expect_kind "registered lead under a new service" scope "$(v2_guard ses_lead "$PROTECTED")"
  pass "guard: a registered lead under a different service incarnation refuses until republication"
}

# B1: a classifier killed by the guard's timeout or by a signal must deny.
break_classifiers() {  # <root> <node-body>
  local f
  for f in "$1"/bin/fm-*-command-policy.mjs; do printf '%s\n' "$2" > "$f"; done
}

test_classifier_signal_death_denies() {
  v2_require_native classifier-signal || return $?
  registered_lead classifier-signal
  positive_control
  break_classifiers "$LEAD_ROOT" 'process.kill(process.pid, "SIGKILL");'
  v2_expect_kind "classifier killed by a signal" "evaluate|scope" "$(v2_guard ses_lead "$ALLOWED")"
  pass "guard: a classifier killed by a signal denies the registered lead"
}

test_classifier_timeout_denies() {
  v2_require_native classifier-timeout || return $?
  registered_lead classifier-timeout
  positive_control
  break_classifiers "$LEAD_ROOT" 'setInterval(() => {}, 1000);'
  v2_expect_kind "classifier that never returns" "evaluate|scope" "$(v2_guard ses_lead "$ALLOWED")"
  pass "guard: a classifier that hangs past the guard timeout denies the registered lead"
}

test_broken_runtime_denies() {
  v2_require_native broken-runtime || return $?
  registered_lead broken-runtime
  positive_control
  local fakebin
  fakebin=$(fm_fakebin "$CASE")
  printf '#!/usr/bin/env bash\necho "node: runtime unavailable" >&2\nexit 1\n' > "$fakebin/node"
  chmod +x "$fakebin/node"
  v2_expect_kind "broken guard runtime" "evaluate|scope|other" \
    "$(v2_guard ses_lead "$ALLOWED" shell "$(jq -nc --arg p "$fakebin:$PATH" '{PATH: $p}')")"
  pass "guard: a broken guard runtime denies the registered lead instead of approving"
}

test_classifier_invalid_verdict_denies() {
  v2_require_native classifier-verdict || return $?
  registered_lead classifier-verdict
  positive_control
  break_classifiers "$LEAD_ROOT" 'console.log("maybe");'
  v2_expect_kind "classifier with a malformed verdict" "evaluate" "$(v2_guard ses_lead "$ALLOWED")"
  pass "guard: a malformed classifier verdict denies the registered lead"
}

# M4: an unreadable registry must not put every unmarked root under lead policy,
# while a marked root still refuses.
test_registry_read_failure_inert_without_marker() {
  v2_require_native registry-unreadable || return $?
  registered_lead registry-unreadable
  positive_control
  v2_session "$CASE" ses_adhoc "$LEAD_ROOT"
  chmod 755 "$HOME/.local/state/shuvbro/opencode-v2/$FM_V2_REGISTRY_NAMESPACE"
  local lead adhoc
  lead=$(v2_guard ses_lead "$PROTECTED")
  adhoc=$(v2_guard ses_adhoc "$PROTECTED")
  chmod 700 "$HOME/.local/state/shuvbro/opencode-v2/$FM_V2_REGISTRY_NAMESPACE"
  v2_expect_kind "marked lead with an unreadable registry" scope "$lead"
  v2_expect_kind "unmarked root with an unreadable registry" allow "$adhoc"
  pass "guard: an unreadable registry refuses the marked lead and leaves unmarked roots inert"
}

# M8: a registered lead whose checkout is a linked worktree is still guarded.
test_linked_lead_checkout_is_guarded() {
  v2_require_native linked-lead || return $?
  CASE="$TMP_ROOT/linked-lead"
  local primary linked
  primary=$(v2_make_guard_root "$CASE/primary")
  linked=$(v2_make_linked_root "$primary" "$CASE/linked")
  cp "$primary"/bin/fm-*-command-policy.mjs "$linked/bin/" 2>/dev/null || { mkdir -p "$linked/bin"; cp "$primary"/bin/fm-*-command-policy.mjs "$linked/bin/"; }
  registered_lead linked-lead "$linked"
  v2_expect_kind "registered lead in a linked checkout" "classifier:persistent-cd" "$(v2_guard ses_lead "$PROTECTED")"
  pass "guard: a registered lead in a linked checkout keeps the cd guard"
}

v2_run_cases \
  test_registered_lead_keeps_classifier_cases \
  test_unrelated_root_session_is_inert \
  test_child_with_inherited_marker_is_inert \
  test_root_with_foreign_marker_is_inert \
  test_worker_location_is_inert \
  test_non_shell_tool_is_not_guarded \
  test_exact_marker_without_record_refuses \
  test_record_protects_when_marker_removed \
  test_retired_lead_refuses_until_rebind \
  test_stale_service_refuses \
  test_classifier_signal_death_denies \
  test_classifier_timeout_denies \
  test_broken_runtime_denies \
  test_classifier_invalid_verdict_denies \
  test_registry_read_failure_inert_without_marker \
  test_linked_lead_checkout_is_guarded
