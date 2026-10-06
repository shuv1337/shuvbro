#!/usr/bin/env bash
# Repro of the 2026-10-06 incident: secondmate sc-mate (harness=opencode-v2,
# backend=herdr) whose Herdr pane is gone. Drives the real bin/fm-bootstrap.sh
# session-start sweep from the checkout given as $1 with fake herdr/node CLIs.
# usage: repro.sh <checkout> <native-execution: idle|executing>
set -u
CHECKOUT=$1 EXEC=${2:-idle}
# Reuse the suite's fixture helpers (world, toolchain stubs) without running its tests.
helpers=$(mktemp); sed -e "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$CHECKOUT/tests/lib.sh\"#" \
  -e '/^test_[a-z0-9_]*$/d' -e '/^echo "# all/d' "$CHECKOUT/tests/fm-secondmate-liveness.test.sh" > "$helpers"
. "$helpers"; rm -f "$helpers"
w=$(new_world "incident-$EXEC")
add_sm_home "$w" sc-mate fm-test:p1 opencode-v2
printf 'backend=herdr\n' >> "$w/home/state/sc-mate.meta"
fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w"); herdrfb=$(fm_fakebin "$w/herdr")
export FM_TEST_HERDR_LOG="$w/herdr.log" FM_TEST_NATIVE_LOG="$w/native.log" FM_TEST_EXECUTION=$EXEC
: > "$FM_TEST_HERDR_LOG"
cat > "$herdrfb/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_HERDR_LOG"
case "${1:-} ${2:-}" in
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
esac
exit 0
SH
cat > "$fb/node" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  *fm-opencode-v2-session.mjs\ status)
    printf '%s\n' "$*" >> "$FM_TEST_NATIVE_LOG"
    case "$FM_TEST_EXECUTION" in idle) echo '{"executing":false}' ;; executing) echo '{"executing":true}' ;; esac ;;
esac
SH
chmod +x "$herdrfb/herdr" "$fb/node"
echo "== checkout: $(git -C "$CHECKOUT" rev-parse --short HEAD)  native execution: $EXEC"
echo "== meta:"; sed 's/^/   /' "$w/home/state/sc-mate.meta"
echo "== bootstrap SECONDMATE_LIVENESS / relaunch lines:"
PATH="$herdrfb:$tmuxfb:$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" FM_TMUX_CALL_LOG="$w/calls.log" \
  FM_BOOTSTRAP_VERBOSE_FACTS=1 "$CHECKOUT/bin/fm-bootstrap.sh" 2>&1 | grep -iE 'sc-mate|secondmate' | sed 's/^/   /'
echo "== native session status probes:"; [ -e "$FM_TEST_NATIVE_LOG" ] && sed 's/^/   /' "$FM_TEST_NATIVE_LOG" || echo "   (none)"
echo "== herdr calls:"; sed 's/^/   /' "$FM_TEST_HERDR_LOG"
