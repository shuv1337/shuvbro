# Leg J (temporary local-test probe): the lead's turn ends idle without draining
# the doorbell; a later wake must re-ring exactly once, and its drain retires all.
if leg J && [ -n "${W1:-}" ] && [ -n "${W2:-}" ]; then
  printf 'kind=ship\n' > "$HOME_A/state/t2.meta"
  : > "$LAB/handled.log"
  ADM="$HOME_A/state/.opencode-v2-admissions"
  phases() { cat "$ADM"/*/msg_*.json 2>/dev/null | jq -c 'select(.kind == "wake") | {phase, rows: (.rows|length), drain}' | sort | tr '\n' ' '; }
  admitted_ever() { cat "$ADM"/*/msg_*.json 2>/dev/null | jq -r 'select(.kind == "wake" and (.phase == "admitted" or .phase == "acknowledged")) | .phase' | wc -l; }
  prompts() { api get "/api/experimental/session/$LEAD_A/export" > "$LAB/transcript-$LEAD_A.json" 2>/dev/null; jq '[.data.messages[]? | select(.type == "user" and (.text | test("WATCHER FIRED")))] | length' "$LAB/transcript-$LEAD_A.json"; }
  lead_idle_after_wake() { api get "/api/experimental/session/$LEAD_A/export" > "$LAB/transcript-$LEAD_A.json" 2>/dev/null; jq -e '.data.messages as $m | ([$m|to_entries[]|select(.value.type=="user" and (.value.text|test("WATCHER FIRED")))|.key]|max) as $u | $u != null and ([$m|to_entries[]|select(.value.type=="idle")|.key]|max // -1) > $u' "$LAB/transcript-$LEAD_A.json" >/dev/null 2>&1; }
  touch "$LAB/ignore-wakes"
  run_in_session "$W1" "printf 'done: w1 ignored doorbell\\n' >> $HOME_A/state/t1.status" || true
  first_prompt() { [ "$(prompts)" -ge 1 ]; }
  wait_until 60 first_prompt || live_fail "J: first doorbell never reached the lead"
  wait_until 60 lead_idle_after_wake || live_fail "J: lead never went idle after ignoring the doorbell"
  sleep 4
  printf 'after-ignored-doorbell (lead idle, no drain; receipt=%s): %s prompts=%s\n' "$(cat "$HOME_A/state/.wake-drain-presented" 2>/dev/null | tr '\t' ' ')" "$(phases)" "$(prompts)" >> "$LAB/legJ.timeline"
  rm -f "$LAB/ignore-wakes"
  run_in_session "$W2" "printf 'done: w2 after idle\\n' >> $HOME_A/state/t2.status" || true
  acks() { local n; n=$(grep -c '^acked ' "$LAB/handled.log" 2>/dev/null); echo "${n:-0}"; }
  one_ack() { [ "$(acks)" -ge 1 ]; }
  wait_until 120 one_ack || live_fail "J: the re-rung doorbell was never handled (lead stranded)"
  sleep 10
  final_prompts=$(prompts)
  printf 'after-re-ring-and-drain: %s prompts=%s acks=%s receipt=%s\n' "$(phases)" "$final_prompts" "$(acks)" "$(cat "$HOME_A/state/.wake-drain-presented" 2>/dev/null | tr '\t' ' ')" >> "$LAB/legJ.timeline"
  outstanding=$(cat "$ADM"/*/msg_*.json 2>/dev/null | jq -r 'select(.kind == "wake" and .phase != "acknowledged") | .phase' | wc -l)
  if [ "$final_prompts" = 2 ] && [ "$(acks)" = 1 ] && [ "$outstanding" = 0 ]; then
    pass "live leg J: an idle lead that ignored its doorbell is re-rung exactly once by the next wake; one drain/ack retires both, no extra prompt"
  else
    live_fail "J: prompts=$final_prompts acks=$(acks) outstanding=$outstanding timeline=$(tr '\n' '|' < "$LAB/legJ.timeline")"
  fi
fi

