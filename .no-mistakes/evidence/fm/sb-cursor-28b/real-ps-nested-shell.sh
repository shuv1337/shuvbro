#!/usr/bin/env bash
# Drives fm_backend_herdr_agent_state(opencode-v2) against a REAL OS process
# tree inside a real pty (script(1)), using the real `ps`. Only Herdr's
# pane/process-info JSON is stubbed (real Herdr lifecycle is forbidden here).
set -u
ROOT=$1; MODE=$2   # MODE: treehouse | other | twohop
W=$(mktemp -d "$HOME/.cache/agent-ws/realps.XXXXXX"); mkdir -p "$W/zd" "$W/fb" "$W/resp"
: > "$W/zd/.zshrc"
case "$MODE" in
  treehouse) inner='(exec -a treehouse bash -c "ZDOTDIR='$W'/zd zsh -l; :" ); :' ;;
  other)     inner='(exec -a script-wrapper bash -c "ZDOTDIR='$W'/zd zsh -l; :" ); :' ;;
  twohop)    inner='(exec -a treehouse bash -c "bash -c \"ZDOTDIR='$W'/zd zsh -l; :\"; :" ); :' ;;
esac
# pane shell = the bash that script(1) runs
( sleep 30 | script -qfec "bash --norc -c '$inner'" /dev/null >/dev/null 2>&1 ) &
for _ in $(seq 50); do zp=$(pgrep -n -x zsh -U "$(id -u)" 2>/dev/null); [ -n "$zp" ] && [ "$(ps -o args= -p "$zp")" = "zsh -l" ] && break; sleep 0.1; done
sleep 0.5
# walk ancestry to find the bash directly under script
p=$zp; chain="$zp"; while :; do pp=$(ps -o ppid= -p "$p" | tr -d ' '); [ "$(ps -o comm= -p "$pp")" = script ] && break; chain="$pp $chain"; p=$pp; done
shell=$p
pgid=$(ps -o tpgid= -p "$zp" | tr -d ' ')
echo "process tree (pane shell -> ... -> foreground):"; for q in $chain; do ps -o pid=,ppid=,stat=,comm=,args= -p "$q"; done
echo "pane shell=$shell foreground pgid=$pgid zsh=$zp"
printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' > "$W/resp/1.out"
for n in 2 3 4 5 6; do printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"zsh","argv":["zsh","-l"]}]}}}\n' "$shell" "$pgid" "$zp" > "$W/resp/$n.out"; done
cat > "$W/fb/herdr" <<'SH'
#!/usr/bin/env bash
R="$FM_HERDR_RESPONSES"; if [ "$1" = status ]; then printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'; exit 0; fi
n=$(( $(cat "$R/.count" 2>/dev/null || echo 0) + 1 )); echo $n > "$R/.count"; cat "$R/$n.out" 2>/dev/null; exit 0
SH
chmod +x "$W/fb/herdr"
verdict=$(PATH="$W/fb:$PATH" FM_HERDR_RESPONSES="$W/resp" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=3 bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state default:w1:p2 opencode-v2' "$ROOT")
echo "MODE=$MODE verdict=$verdict"
pkill -P "$shell" 2>/dev/null; kill "$zp" 2>/dev/null; pkill -f "realps.${W##*.}" 2>/dev/null; rm -rf "$W"
