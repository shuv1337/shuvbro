#!/usr/bin/env bash
# Drive bin/fm-send.sh end-to-end against a fake `herdr` CLI whose `server`
# subcommand prints the papercut's exact error and exits 1. Herdr itself is
# stubbed (live Herdr is out of scope for this test step by user decision).
# Usage: drive-fm-send-herdr.sh <repo-root> <label>
set -u
ROOT=$1 LABEL=$2
W=$(mktemp -d "${HOME}/.cache/agent-ws/fmsend.XXXXXX" 2>/dev/null || mktemp -d)
state=$W/state; mkdir -p "$state" "$W/fakebin"
printf '%s\n' window=default:w1:p2 backend=herdr kind=ship harness=codex > "$state/t1.meta"
cat > "$W/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-}" in
  status) echo '{"server":{"running":false}}' ;;
  server) echo 'error: herdr server is already running' >&2; echo 'api socket: ~/.config/herdr/herdr.sock' >&2; exit 1 ;;
  pane) case "${2:-}" in get) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;; read) printf '\n' ;; esac ;;
  agent) echo '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/sleep"
chmod +x "$W/fakebin/"*
echo "=== [$LABEL] \$ fm-send.sh t1 'run \`herdr server\` only if asked'  (code: $LABEL)"
FM_GATE_REFUSE_BYPASS=1 PATH="$W/fakebin:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_STATE_OVERRIDE="$state" \
  FM_HERDR_LOG="$W/herdr.log" FM_SEND_SETTLE=0 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
  "$ROOT/bin/fm-send.sh" t1 'run `herdr server` only if asked' >"$W/out" 2>"$W/err"
echo "exit code: $?"
echo "--- stdout:"; cat "$W/out"
echo "--- stderr:"; cat "$W/err"
echo "--- inbox record:"; cat "$state"/t1.inbox/*.msg 2>/dev/null || echo "(none)"
echo "--- herdr calls made by fm-send:"; cat "$W/herdr.log"
echo "--- 'herdr server' invocations: $(grep -c '^server\( \|$\)' "$W/herdr.log")"
rm -rf "$W"
