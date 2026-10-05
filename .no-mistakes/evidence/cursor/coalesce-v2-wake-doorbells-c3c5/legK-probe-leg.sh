# Leg K (temporary local-test probe): a burst of worker wakes while the lead is
# busy coalesces behind one undrained steer doorbell; one drain covers all rows.
if leg K && [ -n "${W1:-}" ] && [ -n "${W2:-}" ]; then
  printf 'kind=ship\n' > "$HOME_A/state/t2.meta"
  : > "$LAB/handled.log"
  ADM="$HOME_A/state/.opencode-v2-admissions"
  phases() { cat "$ADM"/*/msg_*.json 2>/dev/null | jq -c 'select(.kind == "wake") | {phase, rows: (.rows|length), drain}' | sort | tr '\n' ' '; }
  admitted_wakes() { cat "$ADM"/*/msg_*.json 2>/dev/null | jq -r 'select(.kind == "wake" and .phase == "admitted") | .phase' | wc -l; }
  api post "/api/session/$LEAD_A/prompt" "$(jq -nc --arg t "RUN: touch $LAB/busy-start; sleep 45; touch $LAB/busy-done" '{text: $t, delivery: "queue"}')" >/dev/null
  busy_started() { [ -e "$LAB/busy-start" ]; }
  wait_until 30 busy_started || live_fail "K: the busy-lead tool never started"
  run_in_session "$W1" "printf 'done: w1 burst one\\n' >> $HOME_A/state/t1.status" || true
  one_admitted() { [ "$(admitted_wakes)" -ge 1 ]; }
  wait_until 60 one_admitted || live_fail "K: first doorbell never admitted"
  printf 'after-first-doorbell: %s\n' "$(phases)" >> "$LAB/legK.timeline"
  run_in_session "$W2" "printf 'done: w2 burst two\\n' >> $HOME_A/state/t2.status" || true
  sleep 6
  printf 'after-second-wake (lead still busy=%s): %s\n' "$([ -e "$LAB/busy-done" ] && echo no || echo yes)" "$(phases)" >> "$LAB/legK.timeline"
  burst_admitted=$(admitted_wakes)
  acks() { local n; n=$(grep -c '^acked ' "$LAB/handled.log" 2>/dev/null); echo "${n:-0}"; }
  one_ack() { [ "$(acks)" -ge 1 ]; }
  wait_until 150 one_ack || live_fail "K: the coalesced doorbell was never handled"
  sleep 10
  printf 'after-drain: %s\n' "$(phases)" >> "$LAB/legK.timeline"
  cp "$HOME_A/state/.wake-drain-presented" "$LAB/legK.drain-receipt" 2>/dev/null || true
  api get "/api/experimental/session/$LEAD_A/export" > "$LAB/transcript-$LEAD_A.json" 2>/dev/null || true
  wake_msgs=$(jq '[.data.messages[]? | select(.type == "user" and (.text | test("WATCHER FIRED")))] | length' "$LAB/transcript-$LEAD_A.json")
  jq -r '.data.messages[]? | select(.type == "user" and (.text | test("WATCHER FIRED"))) | .text' "$LAB/transcript-$LEAD_A.json" > "$LAB/legK.doorbells"
  printf 'burst_admitted=%s wake_prompts=%s acks=%s handled=%s\n' "$burst_admitted" "$wake_msgs" "$(acks)" "$(tr '\n' ';' < "$LAB/handled.log")" >> "$LAB/legK.timeline"
  if [ "$burst_admitted" = 1 ] && [ "$wake_msgs" = 1 ] && [ "$(acks)" = 1 ]; then
    pass "live leg K: two worker wakes during one busy lead turn produced one steer doorbell; one real drain/ack covered both; no second prompt"
  else
    live_fail "K: burst_admitted=$burst_admitted wake_prompts=$wake_msgs acks=$(acks) timeline=$(tr '\n' '|' < "$LAB/legK.timeline")"
  fi
fi

