#!/usr/bin/env bash
# Shared-service worker launcher behavior with a native CLI-shaped fixture.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-v2-launch)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/work"
cat > "$TMP_ROOT/bin/shuvcode" <<'SH'
#!/usr/bin/env bash
set -eu
[ -z "${FM_V2_ACTIVATION:-}" ] && [ -z "${OPENCODE_SESSION_ID:-}" ] || exit 91
if [ "$1" = debug ]; then printf 'state %s\n' "$TEST_NATIVE_STATE"; exit 0; fi
if [ "$1" != api ]; then
  [ "$1" = --server ] && [ "$2" = http://127.0.0.1:12345 ] && [ "$3" = --auto ] && [ "$4" = --session ] && [ "$5" = ses_worker_exact ] && [ "$OPENCODE_PASSWORD" = fixture ] || exit 92
  IFS= read -r input
  [ "$input" = original-terminal-input ] || exit 98
  printf '%s\n' attached >> "$TEST_LOG"
  exit 0
fi
shift
if [ "$1" != --server ]; then echo unsafe-default-autostart >> "$TEST_LOG"; exit 97; fi
[ "$2" = http://127.0.0.1:12345 ] && [ "$OPENCODE_PASSWORD" = fixture ] || exit 97
shift 2
operation=$1
shift
body='' param='' session_param=''
while [ "$#" -gt 0 ]; do
  case "$1" in --data) body=$2; shift 2 ;; --param) param=$2; case "$param" in sessionID=*) session_param=$param ;; esac; shift 2 ;; *) exit 93 ;; esac
done
case "$operation" in
  server.info) jq -cn --argjson pid "$TEST_SERVICE_PID" '{pid:$pid}' ;;
  config.get)
    [ "$param" = "location[directory]=$TEST_WORK" ] || exit 94
    if [ -n "${TEST_CONFIGURED:-}" ]; then
      jq -cn --arg model "$TEST_CONFIGURED" --arg object "${TEST_CONFIGURED_OBJECT:-0}" '[{type:"document",info:{model:"wrong/earlier"}},{type:"directory",path:"/fixture"},{type:"document",info:{model:(if $object=="1" then {providerID:"fixture",model:"test-model",variant:"high"} else $model end)}}]'
    else echo '[]'; fi ;;
  model.list|model.default)
    [ "$param" = "location[directory]=$TEST_WORK" ] || exit 94
    if [ "$operation" = model.default ]; then
      if [ -n "${TEST_CONFIGURED:-}" ]; then echo '{"data":{"id":"external-fallback","providerID":"other-provider","variants":[]}}'; exit 0; fi
      echo '{"data":{"id":"test-model","providerID":"fixture","variants":[{"id":"high"}]}}'
    else
      echo '{"data":[{"id":"test-model","providerID":"fixture","variants":[{"id":"high"}]}]}'
    fi
    [ "${TEST_DROP_REGISTRY:-}" != after-model ] || rm -f "$TEST_NATIVE_STATE/service.json" ;;
  session.create)
    printf '%s\n' "$body" > "$TEST_CREATE"
    jq -e --arg root "$TEST_WORK" '.location.directory==$root and .permissions==[{action:"*",resource:"*",effect:"allow"}]' <<< "$body" >/dev/null
    echo created >> "$TEST_LOG"
    jq -cn --argjson body "$body" '{data:{id:"ses_worker_exact",location:$body.location,model:($body.model + {variant:($body.model.variant // "default")})}}' ;;
  session.prompt)
    [ -f "$TEST_RECORD" ] && [ "$session_param" = sessionID=ses_worker_exact ] && [ "$param" = "location[directory]=$TEST_WORK" ] || exit 95
    jq -e '.sessionID=="ses_worker_exact" and .text=="exact worker brief" and .delivery=="queue"' <<< "$body" >/dev/null
    echo admitted >> "$TEST_LOG"
    echo '{"id":"msg_worker"}'
    [ "${TEST_DROP_REGISTRY:-}" != after-prompt ] || rm -f "$TEST_NATIVE_STATE/service.json" ;;
  session.environment)
    [ "$param" = sessionID=ses_worker_exact ] || exit 95
    jq -e '.variables.TEST_WORK!=null and .variables.FM_V2_ACTIVATION==null and .variables.OPENCODE_SESSION_ID==null and .variables.OPENCODE_PASSWORD==null and .variables.OPENCODE_SERVER_PASSWORD==null' <<< "$body" >/dev/null
    echo environment >> "$TEST_LOG"
    case "${TEST_META_RACE:-}" in remove) rm -f "${TEST_RECORD%.opencode-v2-session.json}.meta" ;; replace) echo replacement > "${TEST_RECORD%.opencode-v2-session.json}.meta" ;; esac ;;
  *) exit 96 ;;
esac
SH
chmod +x "$TMP_ROOT/bin/shuvcode"
export TEST_LOG="$TMP_ROOT/order" TEST_CREATE="$TMP_ROOT/create.json" TEST_RECORD="$TMP_ROOT/worker.opencode-v2-session.json" TEST_WORK="$TMP_ROOT/work"
printf '%s\n' task-fixture > "$TMP_ROOT/worker.meta"
export PATH="$TMP_ROOT/bin:$PATH"
export TEST_NATIVE_STATE="$TMP_ROOT/native-state" TEST_SERVICE_PID=$$
mkdir -p "$TEST_NATIVE_STATE"
jq -cn --argjson pid "$$" '{pid:$pid,url:"http://127.0.0.1:12345",password:"fixture"}' > "$TEST_NATIVE_STATE/service.json"
chmod 600 "$TEST_NATIVE_STATE/service.json"
export FM_V2_ACTIVATION='inherited-wrong-process' OPENCODE_SESSION_ID=ses_parent
printf '%s\n' original-terminal-input > "$TMP_ROOT/input"
for model in default explicit variant configured configured-object; do
  : > "$TEST_LOG"
  args=()
  unset TEST_CONFIGURED TEST_CONFIGURED_OBJECT
  case "$model" in configured*) export TEST_CONFIGURED='fixture/test-model#high' ;; esac
  [ "$model" != configured-object ] || export TEST_CONFIGURED_OBJECT=1
  case "$model" in explicit) args=(--model fixture/test-model) ;; variant) args=(--model 'fixture/test-model#high') ;; esac
  (cd "$TEST_WORK" && "$ROOT/bin/fm-opencode-v2-launch.sh" "${args[@]}" --prompt 'exact worker brief' --session-record "$TEST_RECORD" < "$TMP_ROOT/input") || fail "$model worker launcher"
  [ "$(cat "$TEST_LOG")" = $'created\nenvironment\nadmitted\nattached' ] || fail "$model did not record/admit/attach its exact worker"
  case "$model" in variant|configured*) expected=high ;; *) expected=default ;; esac
  jq -e --arg variant "$expected" '.sessionID=="ses_worker_exact" and .model.variant==$variant' "$TEST_RECORD" >/dev/null || fail "incorrect $model variant record"
  pass "$model worker shares service, records exact session/model, strips activation and admits before attachment"
done

for race in remove replace; do
  printf '%s\n' task-fixture > "$TMP_ROOT/worker.meta"
  : > "$TEST_LOG"
  if (cd "$TEST_WORK" && TEST_META_RACE="$race" "$ROOT/bin/fm-opencode-v2-launch.sh" --model fixture/test-model --prompt 'exact worker brief' --session-record "$TEST_RECORD") 2> "$TMP_ROOT/meta-race-$race"; then
    fail "$race metadata race admitted a worker prompt"
  fi
  assert_contains "$(cat "$TMP_ROOT/meta-race-$race")" 'metadata disappeared or changed' "$race metadata race did not refuse"
  assert_not_contains "$(cat "$TEST_LOG")" admitted "$race metadata race admitted execution"
  assert_not_contains "$(cat "$TEST_LOG")" attached "$race metadata race attached the worker"
  pass "$race task metadata before prompt admission refuses execution"
done
printf '%s\n' task-fixture > "$TMP_ROOT/worker.meta"
unset TEST_CONFIGURED TEST_CONFIGURED_OBJECT
: > "$TEST_LOG"
export TEST_CONFIGURED='fixture/unavailable'
if (cd "$TEST_WORK" && FM_OPENCODE_V2_CATALOG_POLLS=2 "$ROOT/bin/fm-opencode-v2-launch.sh" --prompt 'exact worker brief' --session-record "$TEST_RECORD") 2> "$TMP_ROOT/config-denied"; then
  fail 'unavailable configured default fell back to another model'
fi
[ ! -s "$TEST_LOG" ] || fail 'unavailable configured default started a worker'
unset TEST_CONFIGURED
pass 'configured default refuses rather than selecting an external catalog fallback'
: > "$TEST_LOG"
if (cd "$TEST_WORK" && "$ROOT/bin/fm-opencode-v2-launch.sh" --model 'fixture/test-model#missing' --prompt 'exact worker brief' --session-record "$TEST_RECORD") 2> "$TMP_ROOT/denied"; then
  fail 'unavailable worker variant was accepted'
fi
[ ! -s "$TEST_LOG" ] || fail 'unavailable model variant created or admitted a worker'
pass 'unavailable variant refuses before worker session creation'

# A registered endpoint can vanish between short API calls or after admission
# before attachment. Neither path may run default Service.ensure/auto-start.
cp "$TEST_NATIVE_STATE/service.json" "$TMP_ROOT/saved-registration.json"
for stage in after-model after-prompt; do
  : > "$TEST_LOG"
  rm -f "$TEST_RECORD"
  if (cd "$TEST_WORK" && TEST_DROP_REGISTRY="$stage" "$ROOT/bin/fm-opencode-v2-launch.sh" --model fixture/test-model --prompt 'exact worker brief' --session-record "$TEST_RECORD" < "$TMP_ROOT/input") 2> "$TMP_ROOT/disappeared-$stage"; then
    fail "$stage endpoint disappearance was accepted"
  fi
  assert_contains "$(cat "$TMP_ROOT/disappeared-$stage")" unregistered "$stage did not refuse the missing exact registration"
  assert_not_contains "$(cat "$TEST_LOG")" unsafe-default-autostart "$stage attempted default service startup"
  assert_not_contains "$(cat "$TEST_LOG")" attached "$stage attached to a default/replacement service"
  if [ "$stage" = after-model ]; then
    [ ! -f "$TEST_RECORD" ] && [ ! -s "$TEST_LOG" ] || fail 'pre-admission disappearance created a session or sidecar'
  else
    [ -f "$TEST_RECORD" ] || fail 'post-admission disappearance lost its recorded session'
  fi
  cp "$TMP_ROOT/saved-registration.json" "$TEST_NATIVE_STATE/service.json"
  chmod 600 "$TEST_NATIVE_STATE/service.json"
  pass "$stage registration disappearance refuses without default service auto-start"
done
