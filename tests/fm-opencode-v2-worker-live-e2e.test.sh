#!/usr/bin/env bash
# Credentialed shuvcode worker launch, permissions, steering and semantic hooks.
# Run with FM_OPENCODE_V2_WORKER_LIVE=1; optionally set FM_OPENCODE_V2_MODEL
# (default opencode/space-bunny-free) and FM_OPENCODE_V2_EFFORT (default low).
# Uses an isolated XDG shared service, registry namespace, private tmux socket,
# disposable project/worktree and FM_HOME. Refuses non-lab native paths. Only
# Treehouse allocation is stubbed; fm-spawn, shuvcode, tools and hooks are real.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_OPENCODE_V2_WORKER_LIVE shuvcode tmux jq git node
VERSION=$(shuvcode --version)
MODEL=${FM_OPENCODE_V2_MODEL:-opencode/space-bunny-free}
EFFORT=${FM_OPENCODE_V2_EFFORT:-low}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-v2-live.XXXXXX")
SOCKET="$LAB/tmux.sock"
REAL_TMUX=$(command -v tmux)
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WORKTREE="$LAB/worktree"
FAKEBIN="$LAB/bin"
ID=v2-live
TARGET=firstmate:fm-v2-live
OBSERVER=
SERVICE_STARTED=0
SERVICE_IDENTITY=
export FM_V2_REGISTRY_NAMESPACE="test-worker-live-$$-$RANDOM"
export XDG_CONFIG_HOME="$LAB/xdg/config" XDG_STATE_HOME="$LAB/xdg/state" XDG_DATA_HOME="$LAB/xdg/data" XDG_CACHE_HOME="$LAB/xdg/cache"
unset OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT OPENCODE_SESSION_ID FM_V2_ACTIVATION OPENCODE_PASSWORD OPENCODE_SERVER_PASSWORD
NODE_DIR=$(dirname "$(node -p process.execPath)")
export PATH="$NODE_DIR:$PATH"
cleanup() {
  local status=$?
  if [ -n "$OBSERVER" ]; then
    kill "$OBSERVER" 2>/dev/null || true
    wait "$OBSERVER" 2>/dev/null || true
  fi
  "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  if [ "$SERVICE_STARTED" = 1 ]; then
    local pid current
    pid=$(jq -er '.pid' "$LAB/xdg/state/shuvcode/service.json" 2>/dev/null) || pid=''
    current=$(node "$ROOT/bin/fm-opencode-v2-owner.mjs" identity "$pid" 2>/dev/null) || current=''
    if [ -n "$current" ] && [ "$current" = "$SERVICE_IDENTITY" ]; then
      shuvcode service stop >/dev/null 2>&1 || status=1
      if node "$ROOT/bin/fm-opencode-v2-owner.mjs" identity "$pid" >/dev/null 2>&1; then status=1; fi
    else
      echo 'not ok - isolated service identity changed; refusing service stop' >&2
      status=1
    fi
  fi
  node "$ROOT/bin/fm-opencode-v2-owner.mjs" cleanup-test-namespace >/dev/null 2>&1 || status=1
  if [ "$status" -eq 0 ]; then
    rm -rf "$LAB"
  else
    printf 'not ok - %s live evidence retained at %s\n' "$VERSION" "$LAB" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
paths=$(shuvcode debug paths)
for kind in config state data cache; do
  value=$(awk -v k="$kind" '$1 == k {print $2}' <<< "$paths")
  case "$value" in "$LAB"/*) ;; *) fail "refusing live worker test: native $kind path is outside the lab" ;; esac
done
PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
shuvcode service set port "$PORT" >/dev/null
shuvcode service start >/dev/null
SERVICE_STARTED=1
SERVICE_PID=$(jq -er '.pid' "$LAB/xdg/state/shuvcode/service.json")
SERVICE_IDENTITY=$(node "$ROOT/bin/fm-opencode-v2-owner.mjs" identity "$SERVICE_PID")
SERVICE_URL=$(jq -er '.url' "$LAB/xdg/state/shuvcode/service.json")
export OPENCODE_PASSWORD
OPENCODE_PASSWORD=$(jq -er '.password' "$LAB/xdg/state/shuvcode/service.json")
api() { shuvcode api --server "$SERVICE_URL" "$@"; }
mkdir -p "$FAKEBIN"
fm_test_spawn_home "$HOME_DIR" opencode-v2
fm_git_init_commit "$PROJECT"
cat > "$PROJECT/opencode.json" <<'JSON'
{"update":"disable","permissions":[{"action":"shell","resource":"*","effect":"ask"},{"action":"shell","resource":"*denied-proof*","effect":"deny"}]}
JSON
git -C "$PROJECT" add opencode.json
git -C "$PROJECT" -c user.name=Test -c user.email=test@example.invalid commit -qm "fixture permissions"
fm_git_add_origin "$PROJECT" "$PROJECT.origin.git"
git -C "$PROJECT" worktree add --quiet -b v2-live "$WORKTREE"
fm_test_spawn_brief "$HOME_DIR" "$ID" 'This is a diagnostic fixture, not project work. Use shell to execute: sleep 3; printf ALLOWED > allowed-proof.txt. Then attempt exactly: touch denied-proof.txt. That command must be denied: do not retry or work around denial with another tool. Reply FIXTURE_DONE. Do not supervise, commit, or start validation. Stay ready for a follow-up.'
# The stub enters a real pre-created worktree rather than touching a user's pool.
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = get ] || exit 0
cd "$V2_LIVE_WORKTREE"
exec bash --noprofile --norc
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exec "$V2_LIVE_TMUX" -S "$V2_LIVE_SOCKET" "$@"
SH
chmod +x "$FAKEBIN/treehouse" "$FAKEBIN/tmux"
export V2_LIVE_WORKTREE="$WORKTREE" V2_LIVE_TMUX="$REAL_TMUX" V2_LIVE_SOCKET="$SOCKET"
export PATH="$FAKEBIN:$PATH"
unset TMUX HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
"$REAL_TMUX" -S "$SOCKET" -f /dev/null new-session -d -s firstmate -x 160 -y 50 -c "$PROJECT" 'bash --noprofile --norc'
"$REAL_TMUX" -S "$SOCKET" set-option -g default-command 'bash --noprofile --norc'
"$REAL_TMUX" -S "$SOCKET" set-option -g default-shell /bin/bash
capture() { tmux capture-pane -p -t "$TARGET" -S -200 > "$LAB/screen.txt"; }
# Observe semantic busy before the prompt can finish, independently of spawn's
# initial busy seed. The observer starts before fm-spawn's submission handshake.
(
  for _ in $(seq 1 180); do
    if grep -q 'state=busy source=opencode-plugin' "$HOME_DIR/state/$ID.busy-state" 2>/dev/null; then
      cp "$HOME_DIR/state/$ID.busy-state" "$LAB/observed-busy"
      exit 0
    fi
    sleep 0.5
  done
  exit 1
) &
OBSERVER=$!
if ! FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
  FM_CONFIG_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --harness opencode-v2 --model "$MODEL" \
    --effort "$EFFORT" --backend tmux --mode no-mistakes --yolo off > "$LAB/spawn.log" 2>&1; then
  cat "$LAB/spawn.log" >&2
  capture || true
  fail "$VERSION explicit-model fm-spawn failed"
fi
wait "$OBSERVER" || { capture; fail "$VERSION did not publish semantic busy"; }
OBSERVER=
for _ in $(seq 1 180); do
  if [ -f "$WORKTREE/allowed-proof.txt" ] && [ -f "$HOME_DIR/state/$ID.turn-ended" ] \
    && grep -q 'state=idle source=opencode-plugin' "$HOME_DIR/state/$ID.busy-state"; then
    break
  fi
  sleep 0.5
done
capture
[ "$(cat "$WORKTREE/allowed-proof.txt" 2>/dev/null)" = ALLOWED ] || fail "$VERSION did not auto-approve an ask-policy shell tool"
[ ! -e "$WORKTREE/denied-proof.txt" ] || fail "$VERSION bypassed explicit shell deny"
[ -f "$HOME_DIR/state/$ID.turn-ended" ] || fail "$VERSION did not emit the worker turn-end notification"
grep -q 'state=idle source=opencode-plugin' "$HOME_DIR/state/$ID.busy-state" || fail "$VERSION did not settle semantic idle"
SESSION=$(jq -er --arg dir "$WORKTREE" 'select(.location.directory==$dir) | .sessionID' "$HOME_DIR/state/$ID.opencode-v2-session.json")
api session.get --param "sessionID=$SESSION" --param "location[directory]=$WORKTREE" > "$LAB/session.json"
jq -e --arg model "$MODEL" --arg effort "$EFFORT" '
  .data.model | (.providerID + "/" + .id)==$model and .variant==$effort
' "$LAB/session.json" >/dev/null || fail "$VERSION changed the requested provider/model/variant"
api session.message.list --param "sessionID=$SESSION" --param "location[directory]=$WORKTREE" > "$LAB/messages.json"
jq -e --arg model "$MODEL" --arg effort "$EFFORT" '
  [.data[] | select(.type=="assistant") | .model] as $models
  | ($models | length)>0 and all($models[]; (.providerID + "/" + .id)==$model and .variant==$effort)
' "$LAB/messages.json" >/dev/null || fail "$VERSION assistant used a different provider/model/variant"
# A missing file alone could mean the model never tried the denied command.
jq -e '.. | objects | select(.type?=="tool" and .name?=="shell") | select((.state.input.command? // "") | contains("denied-proof")) | select(.state.status=="error" and .state.error.type=="permission.rejected")' \
  "$LAB/messages.json" >/dev/null || fail "$VERSION did not record a real denied tool attempt"
rm "$HOME_DIR/state/$ID.turn-ended"
# Use the same persistent root composer for a second turn, never a new run.
tmux send-keys -t "$TARGET" -l 'Use shell to execute printf FOLLOWUP > followup-proof.txt. Reply FOLLOWUP_DONE.'
tmux send-keys -t "$TARGET" Enter
for _ in $(seq 1 180); do
  if [ -f "$WORKTREE/followup-proof.txt" ] && [ -f "$HOME_DIR/state/$ID.turn-ended" ] \
    && grep -q 'state=idle source=opencode-plugin' "$HOME_DIR/state/$ID.busy-state"; then
    break
  fi
  sleep 0.5
done
capture
[ "$(cat "$WORKTREE/followup-proof.txt" 2>/dev/null)" = FOLLOWUP ] || fail "$VERSION lost persistent follow-up steering"
[ -f "$HOME_DIR/state/$ID.turn-ended" ] || fail "$VERSION follow-up did not notify turn end"
grep -q 'state=idle source=opencode-plugin' "$HOME_DIR/state/$ID.busy-state" || fail "$VERSION follow-up did not settle semantic idle"
api session.get --param "sessionID=$SESSION" --param "location[directory]=$WORKTREE" | jq -e --arg model "$MODEL" --arg effort "$EFFORT" '
  .data.model | (.providerID + "/" + .id)==$model and .variant==$effort
' >/dev/null || fail "$VERSION follow-up changed provider/model/variant"
api session.message.list --param "sessionID=$SESSION" --param "location[directory]=$WORKTREE" | jq -e --arg model "$MODEL" --arg effort "$EFFORT" '
  [.data[] | select(.type=="assistant") | .model] as $models
  | ($models | length)>0 and all($models[]; (.providerID + "/" + .id)==$model and .variant==$effort)
' >/dev/null || fail "$VERSION follow-up assistant used a different provider/model/variant"
pass "$VERSION explicit model/variant, unattended ask, explicit deny, busy/idle, turn-end and persistent follow-up"
