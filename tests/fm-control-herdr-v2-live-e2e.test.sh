#!/usr/bin/env bash
# Real shuvcode exit/relaunch through a real Treehouse nested login shell on
# Herdr. The nested shell is Herdr's configured pane shell ([terminal]
# default_shell, else $SHELL, else /bin/sh), not a hardcoded zsh.
# Opt in with FM_CONTROL_HERDR_V2_LIVE=1 (submits diagnostic prompts).
# FM_HERDR_LAB_HELPER and FM_HERDR_LAB_LABEL select the guarded helper and lab label.
# Every Herdr call uses the guarded named-session helper, including backend
# calls routed through a lab-only CLI shim. XDG, mise approval, service and
# worker registry settings are confined to the lab subshell and task pane.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_CONTROL_HERDR_V2_LIVE shuvcode herdr treehouse jq git node npm
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr-v2.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name "${FM_HERDR_LAB_LABEL:-control-v2-live}")
ORIGINAL_PATH=$PATH
HERDR_SHELL_CONFIG=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}
export HERDR_LAB_HELPER HERDR_LAB_SESSION ORIGINAL_PATH HERDR_SHELL_CONFIG
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
  # shellcheck disable=SC2329 # Invoked through the EXIT trap below.
  cleanup_service() {
    local status=$? current
    if [ -n "${HOME_DIR:-}" ] && [ -f "$HOME_DIR/state/mate.meta" ]; then
      "$ROOT/bin/fm-control.sh" mate exit > "$LAB/mate-cleanup.log" 2>&1 || status=1
    fi
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
  # Herdr resolves the pane shell from [terminal] default_shell when it is
  # set, otherwise from the server's SHELL, otherwise /bin/sh. Read
  # the same config the running server loaded (resolved before the lab XDG
  # override, which is for shuvcode, not Herdr) so a bash-login host is not
  # required to be zsh.
  configured_shell=
  if [ -f "$HERDR_SHELL_CONFIG" ]; then
    configured_shell=$(awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*\[/ { section=$0; sub(/#.*/, "", section); gsub(/[[:space:]]/, "", section); next }
      section == "[terminal]" && $0 ~ /^[[:space:]]*default_shell[[:space:]]*=/ {
        val=$0
        sub(/^[^=]*=[[:space:]]*/, "", val)
        if (val ~ /^"/) { sub(/^"/, "", val); sub(/".*/, "", val) }
        else if (val ~ /^\047/) { sub(/^\047/, "", val); sub(/\047.*/, "", val) }
        print val
        exit
      }
    ' "$HERDR_SHELL_CONFIG")
  fi
  if [ -z "$configured_shell" ]; then
    configured_shell=${SHELL:-}
  fi
  if [ -z "$configured_shell" ]; then
    configured_shell=/bin/sh
  fi
  configured_shell=${configured_shell##*/}
  configured_shell=${configured_shell#-}
  jq -e --arg shell "$configured_shell" '
    .result.process_info
    | .foreground_process_group_id != .shell_pid
    and (.foreground_processes | length) == 1
    and .foreground_processes[0].name == $shell
  ' "$LAB/after-exit.json" >/dev/null || {
    echo "not ok - after exit the sole nested foreground process was not $configured_shell" >&2
    jq '.result.process_info' "$LAB/after-exit.json" >&2 || true
    exit 1
  }
  "$ROOT/bin/fm-control.sh" nested relaunch --note 'Continue the fixture: reply FIXTURE_DONE, no tools or changes.' > "$LAB/relaunch.log" 2>&1
  grep -q '^relaunched nested harness=opencode-v2 from=opencode-v2' "$LAB/relaunch.log"
  wait_idle
  "$ROOT/bin/fm-control.sh" nested exit > "$LAB/second-exit.log" 2>&1
  grep -q 'native-session=idle' "$LAB/second-exit.log"
  printf 'ok - %s: real Herdr/Treehouse nested-shell exit, in-place relaunch and second exit\n' "$VERSION"

  # Persistent V2 secondmate: a separate code/home root, own lead activation,
  # real session start, parent-channel output, durable profile and relaunch.
  # Copy the candidate's changed tracked files into the disposable clone so
  # this probe also works before the implementation commit.
  MATE="$LAB/mate"
  git clone --quiet --no-hardlinks "$ROOT" "$MATE"
  while IFS= read -r file; do
    [ -f "$ROOT/$file" ] || continue
    mkdir -p "$MATE/$(dirname "$file")"
    cp "$ROOT/$file" "$MATE/$file"
  done < <(git -C "$ROOT" diff --name-only HEAD)
  mkdir -p "$MATE/state" "$MATE/data" "$MATE/config" "$MATE/projects"
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$MATE/.fm-secondmate-parent"
  npm ci --prefix "$MATE/.opencode/plugins" --ignore-scripts > "$LAB/npm.log" 2>&1
  printf 'opencode-v2 %s low\n' "${FM_OPENCODE_V2_MODEL:-opencode/space-bunny-free}" > "$HOME_DIR/config/secondmate-harness"
  printf -- '- mate - isolated V2 fixture (home: %s; scope: diagnostic startup; projects: ; added 2026-10-04)\n' "$MATE" > "$HOME_DIR/data/secondmates.md"
  cat > "$MATE/data/charter.md" <<EOF
# Disposable secondmate diagnostic charter
You are the persistent secondmate in this private home, reporting only to the parent.
Your FM_HOME is $MATE, not the parent home $HOME_DIR.
Run exactly this shell command once now, with no pipe, no tail and no other FM_HOME value:
FM_HOME=$MATE FM_ROOT_OVERRIDE=$MATE FM_STATE_OVERRIDE=$MATE/state FM_CONFIG_OVERRIDE=$MATE/config FM_DATA_OVERRIDE=$MATE/data bin/fm-session-start.sh
Read its full output. Do not separately bootstrap or supervise.
Then use shell to append exactly 'working: V2_SECOND_MATE_STARTED' to $HOME_DIR/state/mate.status.
This is the parent channel. Do not contact the captain or use notifications.
No project work, delegation, audits, validation, or autonomous work is authorized.
Remain idle after the parent status append, and repeat that append after a relaunch.
EOF
  export FM_SKIP_SECONDMATE_SYNC=1
  "$ROOT/bin/fm-spawn.sh" mate --secondmate --backend herdr > "$LAB/mate-spawn.log" 2>&1
  mate_wait() {
    local expected=$1 _ count
    for _ in $(seq 1 240); do
      count=$(grep -c 'V2_SECOND_MATE_STARTED' "$HOME_DIR/state/mate.status" 2>/dev/null || true)
      if [ "${count:-0}" -ge "$expected" ] && node "$ROOT/bin/fm-opencode-v2-session.mjs" status "$HOME_DIR/state/mate.opencode-v2-session.json" "$MATE" | jq -e '.executing==false' >/dev/null; then return 0; fi
      sleep 0.5
    done
    echo "not ok - $VERSION secondmate did not append parent status and settle" >&2
    return 1
  }
  mate_wait 1
  SESSION=$(jq -er .sessionID "$HOME_DIR/state/mate.opencode-v2-session.json")
  jq -e --arg s "$SESSION" --arg h "$MATE" '.sessionID==$s and .root==$h and .home==$h and .state==($h+"/state") and .lifecycle=="active"' "$MATE/state/.opencode-v2-owner.json" >/dev/null
  [ "$(cat "$MATE/state/.lock")" = "$(jq -r .ownerPID "$MATE/state/.opencode-v2-owner.json")" ]
  [ ! -e "$HOME_DIR/state/.opencode-v2-owner.json" ]
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 30 "$ROOT/bin/fm-watch.sh" > "$LAB/parent-notification.log"
  "$ROOT/bin/fm-wake-drain.sh" > "$LAB/parent-wake.log" 2>&1
  grep -q V2_SECOND_MATE_STARTED "$LAB/parent-wake.log"
  ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh --ack-through \([0-9]*\) --recovery-generation \([^ ]*\)$/\1 \2/p' "$LAB/parent-wake.log")
  [ -n "$ack" ] || fail 'parent observation did not produce a generation-bound acknowledgement'
  read -r ack_seq ack_generation <<< "$ack"
  "$ROOT/bin/fm-wake-drain.sh" --ack-through "$ack_seq" --recovery-generation "$ack_generation"
  "$ROOT/bin/fm-control.sh" mate relaunch --note 'Repeat the diagnostic charter startup and parent-channel status; no project work.' > "$LAB/mate-relaunch.log" 2>&1
  mate_wait 2
  [ "$(jq -r .sessionID "$HOME_DIR/state/mate.opencode-v2-session.json")" = "$SESSION" ]
  [ "$(sed -n 's/^harness=//p' "$HOME_DIR/state/mate.meta")" = opencode-v2 ]
  [ "$(sed -n 's/^model=//p' "$HOME_DIR/state/mate.meta")" = "${FM_OPENCODE_V2_MODEL:-opencode/space-bunny-free}" ]
  [ "$(sed -n 's/^effort=//p' "$HOME_DIR/state/mate.meta")" = low ]
  jq -e '.model.variant=="low"' "$HOME_DIR/state/mate.opencode-v2-session.json" >/dev/null
  "$ROOT/bin/fm-control.sh" mate exit > "$LAB/mate-exit.log" 2>&1
  grep -q native-session=idle "$LAB/mate-exit.log"
  "$ROOT/bin/fm-teardown.sh" mate > "$LAB/mate-retire.log" 2>&1
  [ ! -e "$MATE" ] && [ ! -e "$HOME_DIR/state/mate.meta" ]
  printf 'ok - %s: V2 secondmate owns its home, runs startup, delivers parent status, resumes its session/profile and retires cleanly\n' "$VERSION"
)
