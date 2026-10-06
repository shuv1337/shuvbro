#!/usr/bin/env bash
# Drives the real bin/fm-bootstrap.sh session-start sweep against a PRIVATE
# real tmux server (TMUX_TMPDIR isolated) with the real node +
# bin/fm-opencode-v2-session.mjs native-status probe. Only the replacement
# agent binary (codex pin) and unrelated diagnostic CLIs are stand-ins.
# usage: drive-v2-sweep.sh <checkout-root> <scenario>
set -u
ROOT=$1 SC=$2
W=$(mktemp -d /tmp/fmlive-$SC-XXXX)
export TMUX_TMPDIR="$W/tmuxsock"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
FB="$W/bin"; mkdir -p "$FB"
for t in chrome-devtools-axi pi-signed gh herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/$t"; done
rm -f "$FB/herdr"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.46; exit 0\n' > "$FB/lavish-axi"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.29; exit 0\n' > "$FB/gh-axi"
cp "$FB/gh-axi" "$FB/quota-axi"
printf '#!/usr/bin/env bash\n[ "$1 ${2:-}" = "get --help" ] && echo "Usage: treehouse get [--lease]"; exit 0\n' > "$FB/treehouse"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "no-mistakes version v1.46.0 (fake)"; exit 0\n' > "$FB/no-mistakes"
cat > "$FB/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") echo 0.2.4 ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") echo 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
# Replacement agent stand-in: records it was launched, then stays in the foreground.
cat > "$FB/codex" <<SH
#!/usr/bin/env bash
echo "codex-standin launched \$*" >> "$W/agent-launch.log"
exec sleep 600
SH
chmod +x "$FB"/*
NODE_DIR=$(dirname "$(command -v node)")
H="$W/home"; mkdir -p "$H/state" "$H/config"; touch "$H/state/.last-watcher-beat"
echo codex > "$H/config/crew-harness"
SM="$W/sm1"; mkdir -p "$SM/bin" "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
echo sm1 > "$SM/.fm-secondmate-home"; echo '# Firstmate' > "$SM/AGENTS.md"; echo charter > "$SM/data/charter.md"
printf 'window=firstmate:fm-sm1\nkind=secondmate\nharness=opencode-v2\nhome=%s\n' "$SM" > "$H/state/sm1.meta"
PATH="$FB:$NODE_DIR:/usr/bin:/bin" tmux new-session -d -s firstmate -n main 'exec sleep 600'
tmux set-option -g remain-on-exit on; tmux set-option -g default-command "env PATH=$FB:$NODE_DIR:/usr/bin:/bin bash --norc --noprofile"
case "$SC" in
  dead-shell|busy-guard) tmux new-window -d -t firstmate: -n fm-sm1 'exec bash --norc' ;;
  missing) : ;;
esac
if [ "$SC" = busy-guard ]; then
  # A busy record with no recorded native session: real mjs reports executing=null (unproven).
  ( umask 077; printf 'v1 state=busy\n' > "$H/state/sm1.busy-state" )
fi
sleep 0.5
echo "=== scenario: $SC  (checkout: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "$ROOT"))"
echo "--- tmux windows BEFORE:"; tmux list-windows -a -F '#{session_name}:#{window_name} pane_cmd=#{pane_current_command} pane_id=#{pane_id}'
echo "--- real native probe (node fm-opencode-v2-session.mjs status):"
node "$ROOT/bin/fm-opencode-v2-session.mjs" status "$H/state/sm1.opencode-v2-session.json" "$SM" 2>&1 | sed 's/^/    /'
echo "--- fm-bootstrap.sh SECONDMATE_LIVENESS / RESPAWN output:"
FM_GATE_REFUSE_BYPASS=1 PATH="$FB:$NODE_DIR:/usr/bin:/bin" FM_BACKEND=tmux FM_HOME="$H" FM_BOOTSTRAP_VERBOSE_FACTS=1 \
  "$ROOT/bin/fm-bootstrap.sh" > "$W/bootstrap.out" 2>&1; echo "    (bootstrap exit=$?)"
grep -iE 'SECONDMATE|respawn|sm1' "$W/bootstrap.out" | sed 's/^/    /'
sleep 1.5
echo "--- tmux windows AFTER:"; tmux list-windows -a -F '#{session_name}:#{window_name} pane_cmd=#{pane_current_command} pane_id=#{pane_id}'
echo "--- recorded meta AFTER:"; sed "s/^/    /" "$H/state/sm1.meta"
for p in $(tmux list-panes -a -F "#{pane_id}"); do echo "--- pane $p screen:"; tmux capture-pane -p -t "$p" | grep -v "^$" | tail -5 | sed "s/^/    /"; done
echo "--- replacement agent launches:"; cat "$W/agent-launch.log" 2>/dev/null | sed 's/^/    /' || true
[ -e "$W/agent-launch.log" ] || echo "    (none)"
tmux kill-server 2>/dev/null
echo "workdir=$W"
