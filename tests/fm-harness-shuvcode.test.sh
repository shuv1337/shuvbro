#!/usr/bin/env bash
# tests/fm-harness-shuvcode.test.sh - fm-harness.sh own-harness detection for
# shuvcode (OpenCode V2 fork) versus V1 opencode, driven behind a deterministic
# fake ps.
#
# Two process shapes are pinned: the compiled `shuvcode` binary (comm `shuvcode`
# on Linux, the invoked path whose basename is shuvcode on macOS) and the node
# launcher (`node <launcher> ...`, reported as node-MainThread on modern Node
# on Linux). Both must detect as adapter id `opencode-v2` and never as V1
# `opencode`; a real V1 `opencode` binary keeps its own id; and the upstream
# `opencode2` beta is returned as `unknown`, never claimed by either.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-harness-shuvcode)
HARNESS="$ROOT/bin/fm-harness.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
NOPROC="$TMP_ROOT/noproc"

# The always-same fake ps answers every pid with one recorded comm/args pair,
# so each case drives exactly one ancestry evaluation. Unknown queries (ppid)
# exit 1, which terminates the walk after a single hop.
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:-bash}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-bash}"; exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/ps"

# Run detect_own with every marker unset and the fake ps as the only ancestry
# evidence. FM_PROC_ROOT_OVERRIDE keeps the argv[0] probe from reading the real
# /proc, so the verdict cannot depend on this host's own process tree. Extra
# VAR=val arguments are passed through to env to simulate ambient markers.
run_detect() {  # <comm> <args> [VAR=val ...]
  local comm=$1 args=$2
  shift 2
  env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u CLAUDECODE \
      -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
      -u OPENCODE_TERMINAL -u OPENCODE_CONFIG_DIR \
      FAKE_PS_COMM="$comm" FAKE_PS_ARGS="$args" \
      FM_PROC_ROOT_OVERRIDE="$NOPROC" PATH="$FAKEBIN:$PATH" "$@" \
      "$HARNESS" 2>/dev/null
}

test_shuvcode_binary_prints_opencode_v2() {
  local out
  out=$(run_detect 'shuvcode' \
    '/home/shuv/.npm-global/lib/node_modules/shuvcode/node_modules/shuvcode-linux-x64/bin/shuvcode --session ses_abc')
  [ "$out" = opencode-v2 ] || fail "a shuvcode binary ancestry must detect opencode-v2, got '$out'"
  [ "$out" != opencode ] || fail "a shuvcode process was misread as V1 opencode"
  pass "fm-harness.sh: a shuvcode binary ancestry prints opencode-v2"
}

test_shuvcode_node_launcher_prints_opencode_v2() {
  local out
  out=$(run_detect 'node-MainThread' 'node /home/shuv/.local/bin/shuvcode --session ses_abc')
  [ "$out" = opencode-v2 ] || fail "a shuvcode node launcher must detect opencode-v2, got '$out'"
  [ "$out" != opencode ] || fail "a shuvcode launcher was misread as V1 opencode"
  out=$(run_detect node 'node /Users/u/.local/bin/shuvcode --session ses_abc')
  [ "$out" = opencode-v2 ] || fail "a macos-shaped shuvcode node launcher must detect opencode-v2, got '$out'"
  pass "fm-harness.sh: the shuvcode node launcher prints opencode-v2 on linux and macos shapes"
}

test_shared_service_is_not_a_session() {
  local out
  out=$(run_detect shuvcode 'shuvcode serve --service')
  [ "$out" = unknown ] || fail "the shared shuvcode service must not identify as a session, got '$out'"
  out=$(run_detect shuvcode 'shuvcode serve --port 4096 --service')
  [ "$out" = unknown ] || fail "a reordered shared-service flag must not identify as a session, got '$out'"
  out=$(run_detect shuvcode 'shuvcode --service')
  [ "$out" = unknown ] || fail "a top-level shared-service flag must not identify as a session, got '$out'"
  out=$(run_detect shuvcode 'shuvcode serve --stdio --port 0')
  [ "$out" = opencode-v2 ] || fail "a standalone shuvcode server must identify as its session, got '$out'"
  pass "fm-harness.sh: shared service is rejected while standalone server is accepted"
}

test_v1_opencode_still_prints_opencode() {
  local out
  out=$(run_detect opencode 'opencode --prompt')
  [ "$out" = opencode ] || fail "a V1 opencode binary must still detect opencode, got '$out'"
  out=$(run_detect node 'node /opt/opencode/bin/opencode --prompt')
  [ "$out" = opencode ] || fail "a V1 opencode node path must still detect opencode, got '$out'"
  pass "fm-harness.sh: a real V1 opencode still prints opencode"
}

test_opencode2_beta_is_returned_unknown() {
  local out
  out=$(run_detect opencode2 'opencode2 --prompt')
  [ "$out" = unknown ] || fail "an opencode2 beta binary must be unknown, not V1 opencode or opencode-v2, got '$out'"
  out=$(run_detect 'node-MainThread' 'node /opt/tools/opencode2/bin/x --prompt')
  [ "$out" = unknown ] || fail "an opencode2 beta node path must be unknown, got '$out'"
  out=$(run_detect 'node-MainThread' 'node /opt/not-shuvcode/server.js --port 8080')
  [ "$out" = unknown ] || fail "an unrelated node process must be unknown, got '$out'"
  pass "fm-harness.sh: the opencode2 beta and unrelated node processes are returned as unknown"
}

test_ambient_opencode_markers_change_nothing() {
  local out
  # This host itself runs under shuvcode, so a tool env carries
  # OPENCODE_TERMINAL=1 and OPENCODE_CONFIG_DIR=/home/shuv/.config/shuvcode.
  # Those ambient signals must never flip a verdict: an unrelated process stays
  # unknown and a genuine shuvcode ancestor still resolves by ancestry alone.
  out=$(OPENCODE_TERMINAL=1 OPENCODE_CONFIG_DIR=/home/shuv/.config/shuvcode \
        run_detect 'node-MainThread' 'node /opt/shop/server.js --port 8080')
  [ "$out" = unknown ] || fail "ambient shuvcode markers misidentified an unrelated node process, got '$out'"
  out=$(OPENCODE_TERMINAL=1 OPENCODE_CONFIG_DIR=/home/shuv/.config/shuvcode \
        run_detect 'shuvcode' \
        '/home/shuv/.npm-global/lib/node_modules/shuvcode/node_modules/shuvcode-linux-x64/bin/shuvcode --session ses_abc')
  [ "$out" = opencode-v2 ] || fail "a shuvcode ancestor with ambient markers must detect opencode-v2, got '$out'"
  pass "fm-harness.sh: ambient OPENCODE markers never misidentify a process tree"
}

test_claudecode_marker_keeps_existing_precedence() {
  local out
  # The marker layer runs before ancestry; a deliberately-exported CLAUDECODE
  # keeps its existing verdict for an unrelated tree, exactly as it does for
  # the other markerless harnesses.
  out=$(run_detect claude 'claude' CLAUDECODE=1)
  [ "$out" = claude ] || fail "CLAUDECODE=1 must keep detecting claude, got '$out'"
  pass "fm-harness.sh: an exported CLAUDECODE keeps the marker layer's existing precedence"
}

test_shuvcode_ancestry_is_found_several_levels_up() {
  local dir fakebin out
  # A tool subprocess several levels below the shuvcode launch chain: bash
  # child, then the node launcher, then the compiled binary. The walk must
  # climb the whole gap and resolve opencode-v2 from the launcher's own
  # evidence.
  dir="$TMP_ROOT/multihop"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
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
  900:comm=) printf '%s\n' bash ;;
  900:args=) printf '%s\n' 'bash -lc "sleep 1"' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' 'node-MainThread' ;;
  910:args=) printf '%s\n' 'node /home/shuv/.local/bin/shuvcode --session ses_abc' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' shuvcode ;;
  920:args=) printf '%s\n' '/home/shuv/.npm-global/lib/node_modules/shuvcode/node_modules/shuvcode-linux-x64/bin/shuvcode --session ses_abc' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u CLAUDECODE \
        -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
        -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
        -u OPENCODE_TERMINAL -u OPENCODE_CONFIG_DIR \
        FM_PROC_ROOT_OVERRIDE="$dir/noproc" PATH="$fakebin:$PATH" \
        "$HARNESS" 2>/dev/null)
  [ "$out" = opencode-v2 ] || fail "a shuvcode tree several levels up must detect opencode-v2, got '$out'"
  pass "fm-harness.sh: the walk finds shuvcode several ancestors up"
}

test_bootstrap_reports_missing_v2_plugin_runtime() {
  local home out
  home="$TMP_ROOT/bootstrap-runtime"
  mkdir -p "$home"
  cp -R "$ROOT/bin" "$home/bin"
  git init -q "$home"
  : > "$home/AGENTS.md"
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u CLAUDECODE \
        -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
        -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
        -u OPENCODE_TERMINAL -u OPENCODE_CONFIG_DIR \
        FAKE_PS_COMM=shuvcode FAKE_PS_ARGS='shuvcode --standalone --auto' \
        FM_PROC_ROOT_OVERRIDE="$NOPROC" PATH="$FAKEBIN:$PATH" \
        FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip \
        FM_BOOTSTRAP_DETECT_ONLY=1 "$home/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" \
    "MISSING: OpenCode V2 plugin runtime (install: npm ci --prefix $home/.opencode/plugins)" \
    "bootstrap did not report the missing OpenCode V2 plugin runtime"
  pass "fm-bootstrap.sh: a shuvcode primary reports its missing plugin runtime"
}

test_shuvcode_binary_prints_opencode_v2
test_shuvcode_node_launcher_prints_opencode_v2
test_shared_service_is_not_a_session
test_v1_opencode_still_prints_opencode
test_opencode2_beta_is_returned_unknown
test_ambient_opencode_markers_change_nothing
test_claudecode_marker_keeps_existing_precedence
test_shuvcode_ancestry_is_found_several_levels_up
test_bootstrap_reports_missing_v2_plugin_runtime
