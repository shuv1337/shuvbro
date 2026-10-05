#!/usr/bin/env bash
# Drive bin/fm-peek.sh against a stubbed herdr: <root> <running|down>
set -u
ROOT=$1 MODE=$2
W=$(mktemp -d "${HOME}/.cache/agent-ws/fmpeek.XXXXXX"); state=$W/state; mkdir -p "$state" "$W/fakebin"
printf '%s\n' window=default:w1:p2 backend=herdr kind=ship harness=codex > "$state/t1.meta"; touch "$state/.last-watcher-beat"
cat > "$W/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-}" in
  status) if [ "$FM_MODE" = running ]; then echo '{"server":{"running":true}}'; else echo '{"server":{"running":false}}'; fi ;;
  server) echo 'error: herdr server is already running' >&2; exit 1 ;;
  pane) [ "$FM_MODE" = running ] || { echo 'error: herdr server is not running' >&2; exit 1; }
        [ "${2:-}" = read ] && printf 'codex> working on task t1\n' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/sleep"; chmod +x "$W/fakebin/"*
echo "=== \$ fm-peek.sh t1 40   (stub herdr server: $MODE)"
FM_GATE_REFUSE_BYPASS=1 FM_MODE=$MODE PATH="$W/fakebin:$PATH" FM_HOME="$W" FM_ROOT_OVERRIDE="$W" FM_STATE_OVERRIDE="$state" \
  FM_HERDR_LOG="$W/herdr.log" "$ROOT/bin/fm-peek.sh" t1 40 >"$W/out" 2>"$W/err"
echo "exit code: $?"; echo "--- stdout:"; cat "$W/out"; echo "--- stderr:"; cat "$W/err"
echo "--- herdr calls (deduped):"; uniq -c "$W/herdr.log"
rm -rf "$W"
