#!/usr/bin/env bash
# tests/fm-opencode-v2-lead.test.sh - the default OpenCode V2 lead launcher
# (bin/fm-opencode-v2-lead.sh) and the native-executable resolver it shares
# with the session lock (fm_shuvcode_native_binary in bin/fm-shuvcode-lib.sh).
#
# The launcher runs from a fixture code root whose activation script is a stub
# that records its arguments, so every case observes exactly which session and
# executable would be activated without starting a TUI or touching a service.
# `shuvcode` on PATH is a fake npm launcher inside a fake package tree: it
# answers `session list` from a fixture file (honoring --max-count) and records `api session.create`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-lead)

case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) ARCH=unsupported ;;
esac
TRUE_BIN=$(type -P true)

# A fixture code root carrying the launcher, its resolver lib, and a stub
# activation that records its arguments instead of exec'ing a TUI.
make_root() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-opencode-v2-lead.sh" "$ROOT/bin/fm-shuvcode-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-opencode-v2-primary.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$(dirname "$0")/../primary-args"
SH
  chmod +x "$dir/bin/fm-opencode-v2-primary.sh"
  (cd -P "$dir" && pwd -P)
}

# A fake npm install: <pkg>/bin/launcher.sh is the node-style launcher (here a
# bash fake CLI) and the platform binary lives at <platform-root>/<name>/bin.
make_package() {  # <pkg> <platform-root> -> prints the fakebin dir
  local pkg=$1 platform_root=$2 fakebin
  mkdir -p "$pkg/bin" "$platform_root/shuvcode-linux-$ARCH/bin"
  cp "$TRUE_BIN" "$platform_root/shuvcode-linux-$ARCH/bin/shuvcode"
  cat > "$pkg/bin/launcher.sh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "session list")
    max=''
    while [ "$#" -gt 0 ]; do
      [ "$1" = --max-count ] && max=$2
      shift
    done
    if [ -n "$max" ]; then jq -c --argjson n "$max" '.[:$n]' "$FAKE_SESSIONS"; else cat "$FAKE_SESSIONS"; fi
    ;;
  "api session.create")
    printf '%s\n' "$4" >> "$FAKE_CREATED"
    printf '{"data":{"id":"ses_created","location":%s}}\n' "$(jq -c .location <<< "$4")"
    ;;
  *) exit 9 ;;
esac
SH
  chmod +x "$pkg/bin/launcher.sh"
  fakebin=$(fm_fakebin "$pkg/..")
  ln -sf "$pkg/bin/launcher.sh" "$fakebin/shuvcode"
  printf '%s\n' "$fakebin"
}

# Nested layout used by most cases: platform packages under <pkg>/node_modules.
setup_case() {  # <name>: sets CASE ROOT_DIR FAKEBIN NATIVE
  CASE="$TMP_ROOT/$1"
  ROOT_DIR=$(make_root "$CASE/root")
  FAKEBIN=$(make_package "$CASE/npm/shuvcode" "$CASE/npm/shuvcode/node_modules")
  NATIVE=$(readlink -f "$CASE/npm/shuvcode/node_modules/shuvcode-linux-$ARCH/bin/shuvcode")
  printf '[]\n' > "$CASE/sessions.json"
  : > "$CASE/created"
}

run_lead() {  # [args...]: runs the fixture launcher; sets OUT RC
  OUT=$(env -u FM_ROOT_OVERRIDE -u FM_OPENCODE_V2_BIN PATH="$FAKEBIN:$PATH" \
    FAKE_SESSIONS="$CASE/sessions.json" FAKE_CREATED="$CASE/created" \
    "$ROOT_DIR/bin/fm-opencode-v2-lead.sh" "$@" 2>&1) && RC=0 || RC=$?
}

primary_args() { cat "$ROOT_DIR/primary-args" 2>/dev/null; }

resolve_in() {  # <fakebin> [VAR=val ...]: runs the resolver with that PATH
  local fakebin=$1
  shift
  # shellcheck disable=SC2016 # expanded by the child bash
  env -u FM_OPENCODE_V2_BIN "$@" PATH="$fakebin:$PATH" bash -c '. "$1"; fm_shuvcode_native_binary' _ "$ROOT/bin/fm-shuvcode-lib.sh"
}

test_resolver_prefers_platform_binary_over_launcher() {
  setup_case resolve-nested
  local got
  got=$(resolve_in "$FAKEBIN") || fail "the nested platform binary was not resolved"
  assert_equals "$NATIVE" "$got" "the resolver must return the platform binary, never the forking launcher"

  local hoisted="$TMP_ROOT/resolve-hoisted" fakebin
  fakebin=$(make_package "$hoisted/node_modules/shuvcode" "$hoisted/node_modules")
  got=$(resolve_in "$fakebin") || fail "the hoisted platform binary was not resolved"
  assert_equals "$(readlink -f "$hoisted/node_modules/shuvcode-linux-$ARCH/bin/shuvcode")" "$got" \
    "the resolver must find a platform package hoisted beside the launcher package"

  local direct="$TMP_ROOT/resolve-direct"
  fakebin=$(fm_fakebin "$direct")
  cp "$TRUE_BIN" "$direct/shuvcode-native"
  ln -sf "$direct/shuvcode-native" "$fakebin/shuvcode"
  got=$(resolve_in "$fakebin") || fail "a native shuvcode already on PATH was not resolved"
  assert_equals "$(readlink -f "$direct/shuvcode-native")" "$got" "a native executable on PATH is its own answer"
  pass "resolver: the native platform executable is found nested, hoisted, or directly on PATH"
}

test_resolver_refuses_non_native_candidates() {
  setup_case resolve-refuse
  local got rc
  got=$(resolve_in "$FAKEBIN" FM_OPENCODE_V2_BIN="$CASE/npm/shuvcode/bin/launcher.sh") && rc=0 || rc=$?
  expect_code 1 "$rc" "an explicit script override must be refused, got '$got'"
  got=$(resolve_in "$FAKEBIN" FM_OPENCODE_V2_BIN="$TRUE_BIN") || fail "an explicit native override was refused"
  assert_equals "$(readlink -f "$TRUE_BIN")" "$got" "an explicit native override is the only candidate"
  rm -rf "$CASE/npm/shuvcode/node_modules"
  got=$(resolve_in "$FAKEBIN") && rc=0 || rc=$?
  expect_code 1 "$rc" "a launcher without any platform package must not resolve, got '$got'"
  pass "resolver: script overrides and a launcher with no platform package resolve to nothing"
}

test_continue_resumes_newest_exact_root_session() {
  setup_case continue
  jq -n --arg root "$ROOT_DIR" '[
    {id: "ses_worktree", updated: 900, directory: ($root + "/.worktrees/x")},
    {id: "ses_sibling", updated: 800, directory: ($root + "-copy")},
    {id: "ses_root_new", updated: 700, directory: $root},
    {id: "ses_root_old", updated: 100, directory: $root}
  ]' > "$CASE/sessions.json"
  run_lead
  expect_code 0 "$RC" "continue must succeed: $OUT"
  assert_equals "--session ses_root_new --native-binary $NATIVE" "$(primary_args)" \
    "continue must activate the newest session at exactly this code root with the native executable"
  [ ! -s "$CASE/created" ] || fail "continue created a session although one exists at the root"
  pass "launcher: continue activates the newest exact-root session, ignoring newer worktree and sibling sessions"
}

test_continue_without_root_session_creates_one() {
  setup_case continue-create
  jq -n --arg root "$ROOT_DIR" '[{id: "ses_elsewhere", updated: 900, directory: ($root + "/sub")}]' > "$CASE/sessions.json"
  run_lead --continue
  expect_code 0 "$RC" "continue with no root session must succeed: $OUT"
  assert_equals "--session ses_created --native-binary $NATIVE" "$(primary_args)" "continue must activate the session it created"
  jq -e --arg root "$ROOT_DIR" '.location.directory == $root' "$CASE/created" >/dev/null \
    || fail "the session was not created at the code root: $(cat "$CASE/created")"
  pass "launcher: continue with no session at the code root creates one there and activates it"
}

test_continue_refuses_when_window_may_be_truncated() {
  setup_case continue-truncated
  jq -n --arg root "$ROOT_DIR" '[range(10000) | {id: "ses_wt_\(.)", updated: (20000 - .), directory: ($root + "/.worktrees/w\(.)")}]
    + [{id: "ses_root_old", updated: 1, directory: $root}]' > "$CASE/sessions.json"
  run_lead --continue
  expect_code 2 "$RC" "continue must stop when the session list may be truncated: $OUT"
  assert_contains "$OUT" "--session ID or --new" "the refusal must say how to choose a session"
  [ ! -s "$CASE/created" ] || fail "continue created a session although the list may be truncated"
  [ ! -e "$ROOT_DIR/primary-args" ] || fail "the activation ran although the list may be truncated"
  pass "launcher: continue refuses to create a session when the session list fills its whole window"
}

test_new_always_creates() {
  setup_case new
  jq -n --arg root "$ROOT_DIR" '[{id: "ses_root", updated: 900, directory: $root}]' > "$CASE/sessions.json"
  run_lead --new
  expect_code 0 "$RC" "new must succeed: $OUT"
  assert_equals "--session ses_created --native-binary $NATIVE" "$(primary_args)" "new must activate a freshly created session"
  pass "launcher: new creates a fresh session even when one exists at the code root"
}

test_explicit_session_and_binary_pass_through() {
  setup_case explicit
  printf 'not json\n' > "$CASE/sessions.json"
  run_lead --session ses_exact --native-binary "$TRUE_BIN"
  expect_code 0 "$RC" "an explicit session must succeed without discovery: $OUT"
  assert_equals "--session ses_exact --native-binary $TRUE_BIN" "$(primary_args)" "explicit values must reach the activation unchanged"
  [ ! -s "$CASE/created" ] || fail "an explicit session created another session"
  pass "launcher: an explicit session and native executable pass straight to the activation"
}

test_unresolvable_binary_stops_before_activation() {
  setup_case no-binary
  rm -rf "$CASE/npm/shuvcode/node_modules"
  run_lead --session ses_exact
  expect_code 2 "$RC" "an unresolvable native executable must stop the launch"
  assert_contains "$OUT" "--native-binary PATH" "the refusal must say how to supply the executable"
  [ ! -e "$ROOT_DIR/primary-args" ] || fail "the activation ran without a native executable"
  pass "launcher: an unresolvable native executable stops before activation and names --native-binary"
}

if [ "$ARCH" = unsupported ] || [ "$(uname -s)" != Linux ]; then
  printf 'skip - native V2 lead activation is Linux x64/arm64 only (%s %s)\n' "$(uname -s)" "$(uname -m)"
  exit 0
fi

test_resolver_prefers_platform_binary_over_launcher
test_resolver_refuses_non_native_candidates
test_continue_resumes_newest_exact_root_session
test_continue_without_root_session_creates_one
test_continue_refuses_when_window_may_be_truncated
test_new_always_creates
test_explicit_session_and_binary_pass_through
test_unresolvable_binary_stops_before_activation
