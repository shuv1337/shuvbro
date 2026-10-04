#!/usr/bin/env bash
# Drives fm_backend_herdr_agent_state against REAL OS process trees read by the
# host's real `ps` (no FM_HERDR_PS_BIN stub). Only Herdr's own JSON answers
# (pane get / agent get / pane process-info) are stubbed, carrying the real
# pids, because real Herdr lifecycle is out of bounds for this run.
set -u
ROOT=${1:?worktree}; W=$(mktemp -d)
mkdir -p "$W/fb" "$W/zd"; printf 'echo $$ > "%s/fg.pid"\n' "$W" > "$W/zd/.zprofile"
cat > "$W/fb/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1" = status ]; then printf '{"client":{"version":"0.7.5","protocol":14},"server":{"running":true}}\n'; exit 0; fi
case "$*" in
  *"pane get"*) printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' ;;
  *"agent get"*) printf '{"result":{"agent":{"agent":"shuvcode","agent_status":"idle"}}}\n' ;;
  *"process-info"*) printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv":["zsh","-l"]}]}}}\n' "$PANE" "$FG" "$FG" ;;
esac
SH
chmod +x "$W/fb/herdr"
classify() { PATH="$W/fb:$PATH" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state default:w1:p2 "$1"' "$ROOT" "$1"; }
# build <name...>: pane bash -> one process per name (argv0 set via exec -a) -> lone idle `zsh -l`
build() {
  local f="$W/fifo.$RANDOM" s="$W/run.$RANDOM.sh" n; mkfifo "$f"
  local cmd="ZDOTDIR=$W/zd zsh -l <$f >/dev/null 2>&1"
  for n in "$@"; do cmd="(exec -a $n bash -c $(printf %q "$cmd; true")); true"; done
  printf '%s\n' "$cmd" > "$s"
  rm -f "$W/fg.pid"; bash "$s" & PANE=$!
  exec 9>"$f"; sleep 1.5
  FG=$(cat "$W/fg.pid")
  export PANE FG
}
show() {
  echo "--- $1"
  ps -o pid,ppid,stat,args --forest --sid "$(ps -o sid= -p $$ | tr -d ' ')" | grep -v -E 'ps -o|real-process-tree|grep|tr -d'
  echo "stale registration: shuvcode/idle"
  echo "  agent_state(opencode-v2) => $(classify opencode-v2)   [expect $2]"
  echo "  agent_state(no harness)  => $(classify '')   [legacy view]"
  exec 9>&-; sleep 0.5; kill "$PANE" 2>/dev/null; wait "$PANE" 2>/dev/null
}
build treehouse;            show "A: pane shell -> treehouse -> lone idle zsh -l (issue #31 shape)" dead
build script;               show "B: pane shell -> non-Treehouse intermediate (script) -> zsh -l" ambiguous
build treehouse treehouse;  show "C: pane shell -> treehouse -> treehouse -> zsh -l (two hops)" ambiguous
rm -rf "$W"
