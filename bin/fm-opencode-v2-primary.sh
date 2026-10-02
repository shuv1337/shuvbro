#!/usr/bin/env bash
# Explicit native V2 lead activation on the normal shared service.
# Usage: --session ID --native-binary PATH [--server URL]
# PATH must be the installed native executable, not its forking npm wrapper:
# exec preserves the activation's exact PID/start token. Linked copies require
# this explicit activation; ordinary shuvcode/observer clients remain inert.
# External FM_HOME, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE are frozen here.
# Existing live claims refuse replacement; restarting a dead owner is explicit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session='' binary='' server=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session|--native-binary|--server)
      [ "$#" -ge 2 ] || exit 2
      case "$1" in --session) session=$2 ;; --native-binary) binary=$2 ;; --server) server=$2 ;; esac
      shift 2 ;;
    --help|-h) echo 'Usage: fm-opencode-v2-primary.sh --session ID --native-binary PATH [--server URL]'; exit 0 ;;
    *) exit 2 ;;
  esac
done
[[ "$session" =~ ^ses_[A-Za-z0-9_-]+$ ]] || { echo 'error: exact native session ID required' >&2; exit 2; }
[ -x "$binary" ] || { echo 'error: installed native V2 executable required' >&2; exit 2; }
# A script/npm wrapper forks a different execution PID and cannot be activated.
[ "$(head -c 4 "$binary")" = $'\177ELF' ] || { echo 'error: use the native Linux executable, not a forking wrapper' >&2; exit 2; }
root=$(realpath "${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}")
home=$(realpath "${FM_HOME:-$root}")
mkdir -p "${FM_STATE_OVERRIDE:-$home/state}" "${FM_CONFIG_OVERRIDE:-$home/config}"
state=$(realpath "${FM_STATE_OVERRIDE:-$home/state}")
config=$(realpath "${FM_CONFIG_OVERRIDE:-$home/config}")
args=()
[ -z "$server" ] || args=(--server "$server")
service=$(shuvcode api "${args[@]}" server.info | jq -er '.pid')
owner_info=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" identity "$$")
service_info=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" identity "$service")
claim=$(node -e 'console.log(require("node:crypto").randomBytes(24).toString("hex"))')
FM_V2_ACTIVATION=$(jq -cn --arg session "$session" --arg claim "$claim" --arg root "$root" --arg home "$home" --arg state "$state" --arg config "$config" --argjson owner "$owner_info" --argjson service "$service_info" \
  '{version:1,sessionID:$session,claimID:$claim,root:$root,home:$home,state:$state,config:$config,ownerPID:$owner.pid,ownerStart:$owner.start,hostBootID:$owner.boot,servicePID:$service.pid,serviceStart:$service.start,lifecycle:"claimed"}')
export FM_V2_ACTIVATION FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config"
unset OPENCODE_SESSION_ID
cd "$root"
exec "$binary" "${args[@]}" --session "$session"
