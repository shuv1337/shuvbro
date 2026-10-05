#!/usr/bin/env bash
# Unattended native worker on the normal shared execution service.
# Usage: [--secondmate] [--resume] [--model provider/model[#variant]] --prompt TEXT --session-record FILE
# --secondmate activates a home-local lead TUI, not a worker: its own native
# plugin admits TEXT only after claiming that home and freezing its environment.
# The parent-owned FILE still supplies exact-session lifecycle reconciliation.
# An exact recorded session is created before prompt admission; no private
# server/stdin lease is started or killed. --auto applies to this worker TUI.
# FILE is the home-owned task session sidecar passed by fm-spawn, not an RPC
# read target. It records exact worker ID/model plus the service incarnation and
# endpoint for native execution reconciliation before interrupt/cleanup.
# A home with a V2 lead owner record binds workers to that lead's frozen endpoint.
# --resume (fm-spawn --relaunch) continues the session FILE already records,
# keeping its conversation, when that binding names this exact service
# incarnation and worktree, the service still has that root session there, and
# the session has no active execution. An explicit --model that differs from the
# session's switches it natively before admission; without --model the session
# keeps its own model. TEXT is admitted to the resumed session through the same
# queued delivery a fresh worker receives, and FILE is republished from the
# service's own answer. A binding that cannot be resumed falls back to a fresh
# session, announced on stderr; a resumable session that is still executing
# refuses instead. fm-spawn proves the recorded session idle before it runs
# this, so a fresh fallback never abandons active execution.
set -euo pipefail
model_ref='' prompt='' have_prompt=0 record='' resume=0 secondmate=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--prompt|--session-record)
      [ "$#" -ge 2 ] || exit 2
      case "$1" in --model) model_ref=$2 ;; --prompt) prompt=$2; have_prompt=1 ;; --session-record) record=$2 ;; esac
      shift 2 ;;
    --resume) resume=1; shift ;;
    --secondmate) secondmate=1; shift ;;
    --help|-h) echo 'Usage: fm-opencode-v2-launch.sh [--secondmate] [--resume] [--model provider/model[#variant]] --prompt TEXT --session-record FILE'; exit 0 ;;
    *) exit 2 ;;
  esac
done
[ "$have_prompt" -eq 1 ] && [ -n "$record" ] || exit 2
unset FM_V2_ACTIVATION OPENCODE_SESSION_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$record" in *.opencode-v2-session.json) ;; *) echo 'error: native worker requires a task-bound session sidecar' >&2; exit 1 ;; esac
meta=${record%.opencode-v2-session.json}.meta
[ -f "$meta" ] && [ ! -L "$meta" ] || { echo 'error: native worker task metadata is absent or unsafe' >&2; exit 1; }
meta_before=$(cat "$meta")
endpoint=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" lead-endpoint "$(dirname "$record")")
service=$(node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" service ${endpoint:+"$endpoint"})
# Every API read/write targets the verified frozen endpoint. No default service
# discovery/auto-start is allowed after registration, even if it disappears.
api() { node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" api "$@" <<< "$service"; }
directory=$(pwd -P)
if [ "$secondmate" -eq 1 ]; then
  [ "$(sed -n 's/^kind=//p' "$meta")" = secondmate ] && [ "$(realpath "$FM_HOME")" = "$directory" ] \
    || { echo 'error: native secondmate requires its own home and parent secondmate metadata' >&2; exit 1; }
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
  if [ ! -f "$directory/.fm-secondmate-home" ] || [ -L "$directory/.fm-secondmate-home" ] \
    || ! fm_secondmate_parent_record_parse "$directory/.fm-secondmate-parent"; then
    echo 'error: native secondmate requires a seeded home with a valid parent binding' >&2
    exit 1
  fi
  node "$SCRIPT_DIR/fm-opencode-v2-capability.mjs" "$directory" >/dev/null || exit 1
fi
catalog=$(mktemp "${TMPDIR:-/tmp}/fm-v2-catalog.XXXXXX")
trap 'rm -f "$catalog"' EXIT

# Prints the recorded session id when FILE binds a root session at this exact
# worktree on this exact service incarnation and the service still has it.
# Any mismatch or failed read is "not resumable", never an error.
resumable_session() {
  local id info
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  id=$(jq -er --arg dir "$directory" --argjson service "$service" '
    select(.version == 1 and .location.directory == $dir
      and .serviceURL == $service.serviceURL and .servicePID == $service.servicePID
      and .serviceStart == $service.serviceStart and .hostBootID == $service.hostBootID)
    | .sessionID | select(type == "string" and test("^ses_[A-Za-z0-9_-]+$"))' "$record" 2>/dev/null) || return 1
  info=$(api session.get --param "sessionID=$id" --param "location[directory]=$directory" 2>/dev/null) || return 1
  jq -e --arg id "$id" --arg dir "$directory" \
    '.data | .id == $id and .parentID == null and .location.directory == $dir' <<< "$info" >/dev/null 2>&1 || return 1
  printf '%s' "$id"
}

session='' resumed=0
if [ "$resume" -eq 1 ]; then
  if session=$(resumable_session); then
    resumed=1
    # Resuming never joins a running turn: that would admit a second brief
    # beside live work. fm-spawn's gate makes this a race-only refusal.
    api session.active > "$catalog"
    jq -e --arg id "$session" '(.data | type) == "object" and (.data | has($id) | not)' "$catalog" >/dev/null \
      || { echo "error: recorded native worker session $session is executing; refusing to resume it" >&2; exit 1; }
  else
    session=''
    [ ! -e "$record" ] || echo 'note: the recorded native worker session cannot be resumed on this service; starting a fresh session' >&2
  fi
fi

polls=${FM_OPENCODE_V2_CATALOG_POLLS:-60}
case "$polls" in ''|*[!0-9]*|0) exit 2 ;; esac
selected=''
# A resumed session keeps its own model unless one is requested explicitly.
if [ "$resumed" -eq 0 ] || [ -n "$model_ref" ]; then
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
fi
variant=''
case "$model_ref" in
  *'#'*) variant=${model_ref#*#}; [[ "$variant" != *'#'* && -n "$variant" ]] || exit 2
    jq -e --arg variant "$variant" 'any(.variants[]?; .id==$variant)' <<< "$selected" >/dev/null || { echo 'error: requested native variant unavailable' >&2; exit 1; } ;;
esac
if [ "$resumed" -eq 1 ]; then
  args=(--param "sessionID=$session" --param "location[directory]=$directory")
  response=$(api session.get "${args[@]}")
  if [ -n "$selected" ]; then
    wanted=$(jq -cn --argjson selected "$selected" --arg variant "$variant" \
      '{providerID:$selected.providerID,id:$selected.id} | if $variant!="" then .variant=$variant else . end')
    if ! jq -e --argjson wanted "$wanted" \
      '.data.model | .providerID==$wanted.providerID and .id==$wanted.id and (.variant // "default")==($wanted.variant // "default")' <<< "$response" >/dev/null; then
      api session.switchModel "${args[@]}" --data "$(jq -cn --argjson model "$wanted" '{model:$model}')" >/dev/null
      response=$(api session.get "${args[@]}")
      jq -e --argjson wanted "$wanted" \
        '.data.model | .providerID==$wanted.providerID and .id==$wanted.id and (.variant // "default")==($wanted.variant // "default")' <<< "$response" >/dev/null \
        || { echo 'error: native service did not switch the resumed worker session to the requested model' >&2; exit 1; }
    fi
  fi
  jq -e --arg id "$session" --arg dir "$directory" \
    '.data | .id == $id and .parentID == null and .location.directory == $dir' <<< "$response" >/dev/null \
    || { echo 'error: native service changed the resumed worker session identity or location' >&2; exit 1; }
else
  body=$(jq -cn --arg directory "$directory" --argjson selected "$selected" --arg variant "$variant" \
    '{location:{directory:$directory},model:{providerID:$selected.providerID,id:$selected.id}} | if $variant!="" then .model.variant=$variant else . end')
  response=$(api session.create --data "$body")
  if ! session=$(jq -er --argjson expected "$body" '.data | select(.parentID==null and .location.directory==$expected.location.directory and .model.providerID==$expected.model.providerID and .model.id==$expected.model.id and (.model.variant // "default")==($expected.model.variant // "default")) | .id | select(test("^ses_[A-Za-z0-9_-]+$"))' <<< "$response"); then
    echo 'error: native service did not create the requested exact worker session/model' >&2
    exit 1
  fi
fi
umask 077
# Publish through an atomic single-link sidecar before any worker prompt.
temporary=$(mktemp "${record}.XXXXXX")
jq -c --argjson service "$service" '.data | {version:1,sessionID:.id,location:.location,model:.model} + $service' <<< "$response" > "$temporary"
mv "$temporary" "$record"
if [ "$secondmate" -eq 1 ]; then
  # Bind the submission readback to this launch, never an earlier resumed turn.
  messages=$(api session.message.list --param "sessionID=$session" --param "location[directory]=$directory" --param order=desc --param limit=1)
  prior=$(jq -c '.data | if type=="array" then (.[0].id // null) else error("invalid messages") end' <<< "$messages")
  temporary=$(mktemp "${record}.XXXXXX")
  generation=$(sed -n 's/^spawn_gen=//p' "$meta")
  [[ "$generation" =~ ^s[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'error: native secondmate requires a current spawn generation' >&2; exit 1; }
  jq --argjson prior "$prior" --arg generation "$generation" '.launchAfterMessageID=$prior | .spawnGeneration=$generation' "$record" > "$temporary"
  mv "$temporary" "$record"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ "$(cat "$meta")" = "$meta_before" ] \
    || { echo 'error: native secondmate metadata changed before activation' >&2; exit 1; }
  # shellcheck source=bin/fm-shuvcode-lib.sh
  . "$SCRIPT_DIR/fm-shuvcode-lib.sh"
  binary=$(fm_shuvcode_native_binary) || { echo 'error: native secondmate executable is unavailable' >&2; exit 1; }
  rm -f "$catalog"
  trap - EXIT
  FM_ROOT_OVERRIDE="$directory" exec "$SCRIPT_DIR/fm-opencode-v2-primary.sh" --session "$session" --native-binary "$binary" --server "$(jq -er .serviceURL <<< "$service")" --auto --prompt "$prompt"
fi
# Explicit-endpoint TUIs do not perform the managed client's environment push.
# Preserve worker caller routing before admission, without parent activation or
# endpoint credentials. Native execution injects its own exact session ID.
worker_env=$(node -e 'const variables={...process.env}; for(const key of ["FM_V2_ACTIVATION","OPENCODE_SESSION_ID","OPENCODE_PASSWORD","OPENCODE_SERVER_PASSWORD"]) delete variables[key]; console.log(JSON.stringify({variables}))')
api session.environment --param "sessionID=$session" --data "$worker_env" >/dev/null
prompt_body=$(jq -cn --arg session "$session" --arg text "$prompt" '{sessionID:$session,text:$text,delivery:"queue"}')
[ -f "$meta" ] && [ ! -L "$meta" ] && [ "$(cat "$meta")" = "$meta_before" ] \
  || { echo 'error: native worker task metadata disappeared or changed before prompt admission' >&2; exit 1; }
api session.prompt --param "sessionID=$session" --param "location[directory]=$directory" --data "$prompt_body" >/dev/null
rm -f "$catalog"
trap - EXIT
exec node "$SCRIPT_DIR/fm-opencode-v2-owner.mjs" attach "$session" "$service"
