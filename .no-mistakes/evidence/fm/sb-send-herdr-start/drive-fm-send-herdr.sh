#!/usr/bin/env bash
# Drive real fm-send.sh / fm-peek.sh CLIs against a fake `herdr` client on PATH.
# Usage: drive-fm-send-herdr.sh <repo-root> <label> <running:true|false>
set -u
ROOT=$1 LABEL=$2 RUNNING=$3
dir=$(mktemp -d "${HOME}/.cache/agent-ws/fmsend.XXXX"); state=$dir/state; log=$dir/herdr.log
mkdir -p "$state" "$dir/fakebin"; : > "$log"
printf '%s\n' window=default:w1:p2 backend=herdr kind=ship harness=codex > "$state/t1.meta"
cat > "$dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_HERDR_LOG"
case "\${1:-}" in
  status) printf '%s\n' '{"server":{"running":$RUNNING}}' ;;
  server) echo "error: herdr server is already running" >&2; echo "api socket: ~/.config/herdr/herdr.sock" >&2; exit 1 ;;
  pane) case "\${2:-}" in get) printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "\${3:-}";; read) printf 'codex> ready\n';; esac ;;
  agent) printf '%s\n' '{"result":{"agent":{"agent":"codex","agent_status":"idle"}}}' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/sleep"; chmod +x "$dir"/fakebin/*
envs=(-u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1)
echo "=== [$LABEL] server.running=$RUNNING"
echo "\$ fm-send.sh t1 'please continue'"; env "${envs[@]}" "$ROOT/bin/fm-send.sh" t1 'please continue'; echo "exit=$?"
echo "\$ fm-send.sh t1 --key Enter"; env "${envs[@]}" "$ROOT/bin/fm-send.sh" t1 --key Enter; echo "exit=$?"
echo "\$ fm-peek.sh t1"; env "${envs[@]}" "$ROOT/bin/fm-peek.sh" t1 5; echo "exit=$?"
echo "--- inbox:"; cat "$state"/t1.inbox/*.msg 2>/dev/null | head -3
echo "--- herdr calls (server-start lines marked):"; sed 's/^server.*/>>> &   <-- SERVER START/' "$log" | sort | uniq -c
rm -rf "$dir"
