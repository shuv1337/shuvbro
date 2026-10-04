#!/usr/bin/env bash
# Live driver: builds a REAL process tree  tui(comm=shuvcode, "shuvcode -c")
#   -> service(comm=shuvcode, "... serve --service") -> model shell -> real bin/fm-lock.sh
# and runs the worktree's real fm-lock.sh / fm-session-start.sh from inside it.
# Usage: drive-barrier.sh <code-root> <state-dir> <session-id-or-empty> <cmd...>
set -u
ROOT=$1 STATE=$2 SES=$3; shift 3
T=$(mktemp -d /tmp/fm-v2-live.XXXXXX)
mkdir -p "$T/tui" "$T/svc"
ln -s "$(type -P bash)" "$T/tui/shuvcode"
ln -s "$(type -P bash)" "$T/svc/shuvcode"
export ROOT STATE SES T
export CMD="$*"
"$T/tui/shuvcode" -c '
  "$T/svc/shuvcode" -c "
    echo \"--- process ancestry seen by the model shell ---\"
    p=\$\$; for i in 1 2 3 4; do ps -o pid=,comm=,args= -p \$p; p=\$(ps -o ppid= -p \$p | tr -d \" \"); done
    echo \"--- running: \$CMD (OPENCODE_SESSION_ID=\${SES:-<unset>}) ---\"
    if [ -n \"\$SES\" ]; then export OPENCODE_SESSION_ID=\$SES; else unset OPENCODE_SESSION_ID; fi
    FM_STATE_OVERRIDE=\$STATE \$CMD; rc=\$?
    echo \"--- exit code: \$rc ---\"
  " shuvcode serve --service
  true
' 
rm -rf "$T"
