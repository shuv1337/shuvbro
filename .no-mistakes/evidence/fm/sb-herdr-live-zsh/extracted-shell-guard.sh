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
