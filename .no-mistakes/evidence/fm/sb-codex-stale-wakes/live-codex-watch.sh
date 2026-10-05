#!/usr/bin/env bash
# Live drive: real bin/fm-watch.sh watching a real tmux pane (isolated socket)
# that renders a Codex-style Working status row. Prints a transcript.
# usage: live-codex-watch.sh <root-with-bin> <scenario> <duration-secs> <label>
#   scenario: minute-ticking | minute-frozen | seconds-frozen-08
set -u
ROOT=$1 SCEN=$2 DUR=$3 LABEL=$4
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-codex.XXXXXX")
SOCK="fmlive-$$"
mkdir -p "$WORK/state" "$WORK/shim"
cat > "$WORK/shim/tmux" <<EOF
#!/usr/bin/env bash
exec /usr/bin/tmux -L $SOCK "\$@"
EOF
chmod +x "$WORK/shim/tmux"
# Fake Codex TUI: a transcript line, the live status row, and the composer.
cat > "$WORK/codex-ui.sh" <<'EOF'
#!/usr/bin/env bash
scen=$1
render() { clear; printf '• Ran cargo test --workspace\n  └ running 412 tests\n\n%s\n\n› Ask Codex to do anything\n' "$1"; }
case "$scen" in
  minute-ticking) render '• Working (5m • esc to interrupt)'; sleep 55; render '• Working (6m • esc to interrupt)'; sleep 60; render '• Working (7m • esc to interrupt)'; sleep 600 ;;
  minute-frozen)  render '• Working (5m • esc to interrupt)'; sleep 600 ;;
  seconds-frozen-08) render '• Working (1m 08s • esc to interrupt)'; sleep 600 ;;
esac
EOF
chmod +x "$WORK/codex-ui.sh"
PATH="$WORK/shim:$PATH" tmux new-session -d -s fmlive -n codex -x 120 -y 30 "bash $WORK/codex-ui.sh $SCEN"
W=fmlive:codex
printf 'window=%s\nkind=ship\nharness=codex\nbackend=tmux\n' "$W" > "$WORK/state/c1.meta"
sleep 1
echo "=== [$LABEL] scenario=$SCEN root=$ROOT ==="
echo "--- pane (real tmux capture) ---"; PATH="$WORK/shim:$PATH" tmux capture-pane -p -t "$W" | sed '/^$/d'
start=$(date +%s)
PATH="$WORK/shim:$PATH" FM_STATE_OVERRIDE="$WORK/state" FM_POLL=2 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$WORK/watch.out" 2> "$WORK/watch.err" &
pid=$!
exited=no
while [ $(( $(date +%s) - start )) -lt "$DUR" ]; do
  if ! kill -0 "$pid" 2>/dev/null; then exited=yes; break; fi
  sleep 1
done
el=$(( $(date +%s) - start ))
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
echo "--- after ${el}s: watcher exited=$exited ---"
echo "--- pane at end ---"; PATH="$WORK/shim:$PATH" tmux capture-pane -p -t "$W" | grep Working
echo "--- watcher stdout (wakes) ---"; cat "$WORK/watch.out"
echo "--- codex-working observation sidecar ---"; cat "$WORK/state/c1.codex-working" 2>/dev/null || echo '(none)'
echo "--- triage log tail ---"; tail -5 "$WORK/state/.triage.log" 2>/dev/null || ls "$WORK/state" | head -30
echo "--- watcher stderr (octal/arith errors?) ---"; grep -E 'value too great|syntax error' "$WORK/watch.err" || echo '(no arithmetic errors)'
PATH="$WORK/shim:$PATH" tmux kill-server 2>/dev/null
rm -rf "$WORK"
