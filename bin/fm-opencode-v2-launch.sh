#!/usr/bin/env bash
# Unattended native worker on the normal shared execution service.
# Usage: [--model provider/model[#variant]] --prompt TEXT --session-record FILE
# An exact recorded session is created before prompt admission; no private
# server/stdin lease is started or killed. --auto applies to this worker TUI.
# FILE is the home-owned task session sidecar passed by fm-spawn, not an RPC
# read target. It records exact worker ID/model plus the service incarnation and
# endpoint for native execution reconciliation before interrupt/cleanup.
set -euo pipefail
model_ref='' prompt='' have_prompt=0 record=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--prompt|--session-record)
      [ "$#" -ge 2 ] || exit 2
      case "$1" in --model) model_ref=$2 ;; --prompt) prompt=$2; have_prompt=1 ;; --session-record) record=$2 ;; esac
      shift 2 ;;
    --help|-h) echo 'Usage: fm-opencode-v2-launch.sh [--model provider/model[#variant]] --prompt TEXT --session-record FILE'; exit 0 ;;
    *) exit 2 ;;
  esac
done
[ "$have_prompt" -eq 1 ] && [ -n "$record" ] || exit 2
unset FM_V2_ACTIVATION OPENCODE_SESSION_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" service)
# Every API read/write targets the verified frozen endpoint. No default service
# discovery/auto-start is allowed after registration, even if it disappears.
api() { node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" api "$@" <<< "$service"; }
directory=$(pwd -P)
catalog=$(mktemp "${TMPDIR:-/tmp}/fm-v2-catalog.XXXXXX")
trap 'rm -f "$catalog"' EXIT
polls=${FM_OPENCODE_V2_CATALOG_POLLS:-60}
case "$polls" in ''|*[!0-9]*|0) exit 2 ;; esac
selected=''
if [ -z "$model_ref" ]; then
  # model.default may fall back to available[0] while a configured provider is
  # warming. Read the ordered native configuration, never parse local configs.
  config=$(api config.get --param "location[directory]=$directory")
  model_ref=$(jq -er '
    if type!="array" then error("invalid native configuration") else
      [ .[] | select(.type=="document") | .info.model | select(.!=null) ] | last // null |
      if .==null then "" elif type=="string" then .
      elif type=="object" and (.providerID|type)=="string" and (.model|type)=="string" then
        .providerID+"/"+.model+(if .variant!=null then "#"+.variant else "" end)
      else error("invalid configured default model") end
    end' <<< "$config")
fi
for ((i=0; i<polls; i++)); do
  # A regular output file avoids CLI pipe truncation of large catalogs.
  if [ -n "$model_ref" ]; then
    model=${model_ref%%#*}
    provider=${model%%/*}
    model=${model#*/}
    [ "$provider" != "$model" ] && [ -n "$model" ] || exit 2
    api model.list --param "location[directory]=$directory" > "$catalog"
    selected=$(jq -c --arg provider "$provider" --arg model "$model" '.data[] | select(.providerID==$provider and .id==$model)' "$catalog")
  else
    api model.default --param "location[directory]=$directory" > "$catalog"
    selected=$(jq -c '.data // empty' "$catalog")
  fi
  [ -z "$selected" ] || break
  sleep 0.25
done
[ -n "$selected" ] || { echo 'error: requested native shared-service model is unavailable' >&2; exit 1; }
variant=''
case "$model_ref" in
  *'#'*) variant=${model_ref#*#}; [[ "$variant" != *'#'* && -n "$variant" ]] || exit 2
    jq -e --arg variant "$variant" 'any(.variants[]?; .id==$variant)' <<< "$selected" >/dev/null || { echo 'error: requested native variant unavailable' >&2; exit 1; } ;;
esac
body=$(jq -cn --arg directory "$directory" --argjson selected "$selected" --arg variant "$variant" \
  '{location:{directory:$directory},model:{providerID:$selected.providerID,id:$selected.id},permissions:[{action:"*",resource:"*",effect:"allow"}]} | if $variant!="" then .model.variant=$variant else . end')
response=$(api session.create --data "$body")
if ! session=$(jq -er --argjson expected "$body" '.data | select(.parentID==null and .location.directory==$expected.location.directory and .model.providerID==$expected.model.providerID and .model.id==$expected.model.id and (.model.variant // "default")==($expected.model.variant // "default")) | .id | select(test("^ses_[A-Za-z0-9_-]+$"))' <<< "$response"); then
  echo 'error: native service did not create the requested exact worker session/model' >&2
  exit 1
fi
umask 077
# Publish through an atomic single-link sidecar before any worker prompt.
temporary=$(mktemp "${record}.XXXXXX")
jq -c --argjson service "$service" '.data | {version:1,sessionID:.id,location:.location,model:.model} + $service' <<< "$response" > "$temporary"
mv "$temporary" "$record"
# Explicit-endpoint TUIs do not perform the managed client's environment push.
# Preserve worker caller routing before admission, without parent activation or
# endpoint credentials. Native execution injects its own exact session ID.
worker_env=$(node -e 'const variables={...process.env}; for(const key of ["FM_V2_ACTIVATION","OPENCODE_SESSION_ID","OPENCODE_PASSWORD","OPENCODE_SERVER_PASSWORD"]) delete variables[key]; console.log(JSON.stringify({variables}))')
api session.environment --param "sessionID=$session" --data "$worker_env" >/dev/null
prompt_body=$(jq -cn --arg session "$session" --arg text "$prompt" '{sessionID:$session,text:$text,delivery:"queue"}')
api session.prompt --param "sessionID=$session" --param "location[directory]=$directory" --data "$prompt_body" >/dev/null
rm -f "$catalog"
trap - EXIT
exec node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" attach "$session" "$service"
