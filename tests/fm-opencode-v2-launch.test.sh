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
  [ "$1" = --auto ] && [ "$2" = --session ] && [ "$3" = ses_worker_exact ] || exit 92
  printf '%s\n' attached >> "$TEST_LOG"
  exit 0
fi
shift
if [ "$1" = --server ]; then [ "$2" = http://127.0.0.1:12345 ] || exit 97; shift 2; fi
operation=$1
shift
body='' param=''
while [ "$#" -gt 0 ]; do
  case "$1" in --data) body=$2; shift 2 ;; --param) param=$2; shift 2 ;; *) exit 93 ;; esac
done
case "$operation" in
  server.info) jq -cn --argjson pid "$TEST_SERVICE_PID" '{pid:$pid}' ;;
  model.list|model.default)
    [ "$param" = "location[directory]=$TEST_WORK" ] || exit 94
    if [ "$operation" = model.default ]; then
      echo '{"data":{"id":"test-model","providerID":"fixture","variants":[{"id":"high"}]}}'
    else
      echo '{"data":[{"id":"test-model","providerID":"fixture","variants":[{"id":"high"}]}]}'
    fi ;;
  session.create)
    printf '%s\n' "$body" > "$TEST_CREATE"
    jq -e --arg root "$TEST_WORK" '.location.directory==$root and .permissions==[{action:"*",resource:"*",effect:"allow"}]' <<< "$body" >/dev/null
    echo created >> "$TEST_LOG"
    jq -cn --argjson body "$body" '{data:{id:"ses_worker_exact",location:$body.location,model:($body.model + {variant:($body.model.variant // "default")})}}' ;;
  session.prompt)
    [ -f "$TEST_RECORD" ] && [ "$param" = sessionID=ses_worker_exact ] || exit 95
    jq -e '.sessionID=="ses_worker_exact" and .text=="exact worker brief" and .delivery=="queue"' <<< "$body" >/dev/null
    echo admitted >> "$TEST_LOG"
    echo '{"id":"msg_worker"}' ;;
  *) exit 96 ;;
esac
SH
chmod +x "$TMP_ROOT/bin/shuvcode"
export TEST_LOG="$TMP_ROOT/order" TEST_CREATE="$TMP_ROOT/create.json" TEST_RECORD="$TMP_ROOT/session.json" TEST_WORK="$TMP_ROOT/work"
export PATH="$TMP_ROOT/bin:$PATH"
export TEST_NATIVE_STATE="$TMP_ROOT/native-state" TEST_SERVICE_PID=$$
mkdir -p "$TEST_NATIVE_STATE"
jq -cn --argjson pid "$$" '{pid:$pid,url:"http://127.0.0.1:12345",password:"fixture"}' > "$TEST_NATIVE_STATE/service.json"
chmod 600 "$TEST_NATIVE_STATE/service.json"
export FM_V2_ACTIVATION='inherited-wrong-process' OPENCODE_SESSION_ID=ses_parent
for model in default explicit variant; do
  : > "$TEST_LOG"
  args=()
  case "$model" in explicit) args=(--model fixture/test-model) ;; variant) args=(--model 'fixture/test-model#high') ;; esac
  (cd "$TEST_WORK" && "$ROOT/bin/fm-opencode-v2-launch.sh" "${args[@]}" --prompt 'exact worker brief' --session-record "$TEST_RECORD") || fail "$model worker launcher"
  [ "$(cat "$TEST_LOG")" = $'created\nadmitted\nattached' ] || fail "$model did not record/admit/attach its exact worker"
  case "$model" in variant) expected=high ;; *) expected=default ;; esac
  jq -e --arg variant "$expected" '.sessionID=="ses_worker_exact" and .model.variant==$variant' "$TEST_RECORD" >/dev/null || fail "incorrect $model variant record"
  pass "$model worker shares service, records exact session/model, strips activation and admits before attachment"
done
: > "$TEST_LOG"
if (cd "$TEST_WORK" && "$ROOT/bin/fm-opencode-v2-launch.sh" --model 'fixture/test-model#missing' --prompt 'exact worker brief' --session-record "$TEST_RECORD") 2> "$TMP_ROOT/denied"; then
  fail 'unavailable worker variant was accepted'
fi
[ ! -s "$TEST_LOG" ] || fail 'unavailable model variant created or admitted a worker'
pass 'unavailable variant refuses before worker session creation'
