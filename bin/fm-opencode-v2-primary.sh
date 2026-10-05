#!/usr/bin/env bash
# Explicit native V2 lead activation on the normal shared service.
# Usage: --session ID --native-binary PATH [--server URL] [--auto] [--prompt TEXT]
# --prompt is admitted by the native TUI plugin only after exact activation and
# environment publication. --auto enables unattended approval for secondmates.
# PATH must be the installed native executable, not its forking npm wrapper:
# exec preserves the activation's exact PID/start token. Linked copies require
# this explicit activation; ordinary shuvcode/observer clients remain inert.
# External FM_HOME, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE are frozen here.
# Existing live claims refuse replacement; restarting a dead owner is explicit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session='' binary='' server='' prompt='' auto=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session|--native-binary|--server|--prompt)
      [ "$#" -ge 2 ] || exit 2
      case "$1" in --session) session=$2 ;; --native-binary) binary=$2 ;; --server) server=$2 ;; --prompt) prompt=$2 ;; esac
      shift 2 ;;
    --auto) auto=1; shift ;;
    --help|-h) echo 'Usage: fm-opencode-v2-primary.sh --session ID --native-binary PATH [--server URL] [--auto] [--prompt TEXT]'; exit 0 ;;
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
service_info=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" service ${server:+"$server"})
server=$(jq -er '.serviceURL' <<< "$service_info")
# Freeze attachment as well as helper calls; default native resolution could
# otherwise auto-start a different managed service after registration vanished.
# The private credential travels only through the child environment, never the
# activation record or command arguments. Shell exec retains the owning PID.
OPENCODE_PASSWORD=$(node --input-type=module -e 'const {registeredService}=await import(process.argv[2]); const expected=JSON.parse(process.argv[3]), found=registeredService(expected.serviceURL); if(found.pid!==expected.servicePID || found.start!==expected.serviceStart || found.boot!==expected.hostBootID) throw new Error("primary service registration changed incarnation"); process.stdout.write(found.password)' fm-primary-credential "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" "$service_info")
export OPENCODE_PASSWORD
owner_info=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" identity "$$")
claim=$(node -e 'console.log(require("node:crypto").randomBytes(24).toString("hex"))')
FM_V2_ACTIVATION=$(jq -cn --arg session "$session" --arg claim "$claim" --arg root "$root" --arg home "$home" --arg state "$state" --arg config "$config" --argjson owner "$owner_info" --argjson service "$service_info" \
  '{version:1,sessionID:$session,claimID:$claim,root:$root,home:$home,state:$state,config:$config,ownerPID:$owner.pid,ownerStart:$owner.start,hostBootID:$owner.boot,servicePID:$service.servicePID,serviceStart:$service.serviceStart,serviceURL:$service.serviceURL,lifecycle:"claimed"}')
export FM_V2_ACTIVATION FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config"
unset OPENCODE_SESSION_ID
unset FM_V2_LAUNCH_PROMPT
[ -z "$prompt" ] || export FM_V2_LAUNCH_PROMPT="$prompt"
cd "$root"
args=(--server "$server" --session "$session")
[ "$auto" -eq 0 ] || args+=(--auto)
exec "$binary" "${args[@]}"
