#!/usr/bin/env bash
# Unattended native worker on the normal shared execution service.
# Usage: [--model provider/model[#variant]] --prompt TEXT --session-record FILE
# An exact recorded session is created before prompt admission; no private
# server/stdin lease is started or killed. --auto applies to this worker TUI.
# FILE is the home-owned task session sidecar passed by fm-spawn, not an RPC
# read target. It records the exact worker ID/model for busy-event attribution.
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
directory=$(pwd -P)
catalog=$(mktemp "${TMPDIR:-/tmp}/fm-v2-catalog.XXXXXX")
trap 'rm -f "$catalog"' EXIT
polls=${FM_OPENCODE_V2_CATALOG_POLLS:-60}
case "$polls" in ''|*[!0-9]*|0) exit 2 ;; esac
selected=''
for ((i=0; i<polls; i++)); do
  # A regular output file avoids CLI pipe truncation of large catalogs.
  if [ -n "$model_ref" ]; then
    model=${model_ref%%#*}
    provider=${model%%/*}
    model=${model#*/}
    [ "$provider" != "$model" ] && [ -n "$model" ] || exit 2
    shuvcode api model.list --param "location[directory]=$directory" > "$catalog"
    selected=$(jq -c --arg provider "$provider" --arg model "$model" '.data[] | select(.providerID==$provider and .id==$model)' "$catalog")
  else
    shuvcode api model.default --param "location[directory]=$directory" > "$catalog"
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
response=$(shuvcode api session.create --data "$body")
if ! session=$(jq -er --argjson expected "$body" '.data | select(.parentID==null and .location.directory==$expected.location.directory and .model.providerID==$expected.model.providerID and .model.id==$expected.model.id and (.model.variant // "default")==($expected.model.variant // "default")) | .id | select(test("^ses_[A-Za-z0-9_-]+$"))' <<< "$response"); then
  echo 'error: native service did not create the requested exact worker session/model' >&2
  exit 1
fi
umask 077
# Publish through an atomic single-link sidecar before any worker prompt.
temporary=$(mktemp "${record}.XXXXXX")
jq -c '.data | {version:1,sessionID:.id,location:.location,model:.model}' <<< "$response" > "$temporary"
mv "$temporary" "$record"
prompt_body=$(jq -cn --arg session "$session" --arg text "$prompt" '{sessionID:$session,text:$text,delivery:"queue"}')
shuvcode api session.prompt --param "sessionID=$session" --data "$prompt_body" >/dev/null
rm -f "$catalog"
trap - EXIT
exec shuvcode --auto --session "$session"
