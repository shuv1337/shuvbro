#!/usr/bin/env bash
# Real shuvcode exit/relaunch through a real Treehouse nested login shell on
# Herdr. Opt in with FM_CONTROL_HERDR_V2_LIVE=1 (submits diagnostic prompts).
# Every Herdr call uses the guarded named-session helper, including backend
# calls routed through a lab-only CLI shim. XDG, mise approval, service and
# worker registry settings are confined to the lab subshell and task pane.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_CONTROL_HERDR_V2_LIVE shuvcode herdr treehouse jq git node
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr-v2.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name control-v2-live)
ORIGINAL_PATH=$PATH
export HERDR_LAB_HELPER HERDR_LAB_SESSION ORIGINAL_PATH
cleanup_lab() {
  local status=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  if [ "$status" = 0 ]; then rm -rf "$LAB"; else echo "live proof retained at $LAB" >&2; fi
  exit "$status"
}
trap cleanup_lab EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
mkdir -p "$LAB/bin"
cat > "$LAB/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ $# -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$2" = "$HERDR_LAB_SESSION" ] || exit 90
    shift 2
  else
    args+=("$1"); shift
  fi
done
call_helper() {
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u MISE_YES \
    PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}
if [ "${args[0]} ${args[1]:-}" = 'tab create' ]; then
  result=$(call_helper "${args[@]}")
  pane=$(printf '%s' "$result" | jq -er '.result.root_pane.pane_id')
  line=$(printf 'export MISE_YES=1 XDG_CONFIG_HOME=%q XDG_STATE_HOME=%q XDG_DATA_HOME=%q XDG_CACHE_HOME=%q FM_V2_REGISTRY_NAMESPACE=%q; unset OPENCODE_CONFIG_DIR OPENCODE_SESSION_ID FM_V2_ACTIVATION OPENCODE_PASSWORD OPENCODE_SERVER_PASSWORD' "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$FM_V2_REGISTRY_NAMESPACE")
  call_helper pane run "$pane" "$line" >/dev/null
  printf '%s\n' "$result"
else
  call_helper "${args[@]}"
fi
SH
chmod +x "$LAB/bin/herdr"
(
  # shellcheck source=tests/fm-opencode-v2-acceptance-lib.sh
  . "$ROOT/tests/fm-opencode-v2-acceptance-lib.sh"
  v2_assert_test_namespace
  NODE_DIR=$(dirname "$(node -p process.execPath)")
  export PATH="$NODE_DIR:$LAB/bin:$PATH"
  export XDG_CONFIG_HOME="$LAB/xdg/config" XDG_STATE_HOME="$LAB/xdg/state" XDG_DATA_HOME="$LAB/xdg/data" XDG_CACHE_HOME="$LAB/xdg/cache"
  export MISE_YES=1
  unset OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT OPENCODE_CONFIG_PROJECT_DISABLE OPENCODE_DISABLE_PROJECT_CONFIG
  unset OPENCODE_SESSION_ID FM_V2_ACTIVATION OPENCODE_PASSWORD OPENCODE_SERVER_PASSWORD
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
  export HERDR_SESSION="$HERDR_LAB_SESSION"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
  VERSION=$(shuvcode --version)
  PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  shuvcode service set port "$PORT" >/dev/null
  shuvcode service start >/dev/null
  SERVICE_PID=$(jq -er '.pid' "$XDG_STATE_HOME/shuvcode/service.json")
  SERVICE_IDENTITY=$(node "$ROOT/bin/fm-opencode-v2-owner.mjs" identity "$SERVICE_PID")
  cleanup_service() {
    local status=$? current
    current=$(node "$ROOT/bin/fm-opencode-v2-owner.mjs" identity "$SERVICE_PID" 2>/dev/null) || current=''
    if [ "$current" = "$SERVICE_IDENTITY" ]; then shuvcode service stop >/dev/null || status=1; else status=1; fi
    node "$ROOT/bin/fm-opencode-v2-owner.mjs" cleanup-test-namespace >/dev/null || status=1
    v2_teardown
    [ "$V2_TEARDOWN_FAILED" = 0 ] || status=1
    exit "$status"
  }
  trap cleanup_service EXIT
  HOME_DIR="$LAB/home"
  PROJECT="$LAB/project"
  fm_test_spawn_home "$HOME_DIR" opencode-v2
  fm_git_init_commit "$PROJECT"
  printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  printf 'root = "%s"\nmax_trees = 2\n' "$LAB" > "$PROJECT/treehouse.toml"
  git -C "$PROJECT" add treehouse.toml
  git -C "$PROJECT" -c user.name=Test -c user.email=test@example.invalid commit -qm 'fixture Treehouse pool'
  fm_git_add_origin "$PROJECT" "$LAB/project.origin.git"
  fm_test_spawn_brief "$HOME_DIR" nested 'This is a diagnostic fixture. Reply only FIXTURE_DONE. Do not use tools, change files, supervise, or validate. Remain idle for lifecycle testing.'
  export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_SPAWN_NO_GUARD=1
  "$ROOT/bin/fm-spawn.sh" nested "$PROJECT" --harness opencode-v2 \
    --model "${FM_OPENCODE_V2_MODEL:-opencode/space-bunny-free}" --effort low \
    --backend herdr --mode no-mistakes --yolo off > "$LAB/spawn.log" 2>&1
  wait_idle() {
    local _
    for _ in $(seq 1 180); do
      grep -q 'state=idle source=opencode-plugin' "$HOME_DIR/state/nested.busy-state" 2>/dev/null && return 0
      sleep 0.5
    done
    echo "not ok - $VERSION did not settle native execution" >&2
    return 1
  }
  wait_idle
  PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/nested.meta")
  "$ROOT/bin/fm-control.sh" nested exit > "$LAB/exit.log" 2>&1
  herdr pane process-info --pane "$PANE" --session "$HERDR_LAB_SESSION" > "$LAB/after-exit.json"
  jq -e '.result.process_info | .foreground_process_group_id != .shell_pid and (.foreground_processes | length) == 1 and .foreground_processes[0].name == "zsh"' "$LAB/after-exit.json" >/dev/null
  "$ROOT/bin/fm-control.sh" nested relaunch --note 'Continue the fixture: reply FIXTURE_DONE, no tools or changes.' > "$LAB/relaunch.log" 2>&1
  grep -q '^relaunched nested harness=opencode-v2 from=opencode-v2' "$LAB/relaunch.log"
  wait_idle
  "$ROOT/bin/fm-control.sh" nested exit > "$LAB/second-exit.log" 2>&1
  grep -q 'native-session=idle' "$LAB/second-exit.log"
  printf 'ok - %s: real Herdr/Treehouse nested-shell exit, in-place relaunch and second exit\n' "$VERSION"
)
