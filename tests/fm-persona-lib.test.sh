#!/usr/bin/env bash
# Persona resolver: presets, overrides, invalid config, isolation, inheritance,
# protocol headings, and session/worker consumers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-persona-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-persona)
PERSONA="$ROOT/bin/fm-persona-lib.sh"

home_pair() {
  local name=$1
  mkdir -p "$TMP_ROOT/$name/a/config" "$TMP_ROOT/$name/b/config"
  printf '%s\n' "$TMP_ROOT/$name/a|$TMP_ROOT/$name/b"
}

dump_home() {
  local home=$1
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$PERSONA" --dump
}

test_absent_defaults_to_bro() {
  local home dump
  home="$TMP_ROOT/absent"
  mkdir -p "$home/config"
  dump=$(dump_home "$home") || fail "absent config should load"
  printf '%s\n' "$dump" | grep -qx 'preset=bro' || fail "absent config preset"
  printf '%s\n' "$dump" | grep -qx 'lead=Bro' || fail "absent config lead"
  printf '%s\n' "$dump" | grep -qx 'user=dude' || fail "absent config user"
  printf '%s\n' "$dump" | grep -qx 'worker=worker' || fail "absent config worker"
  printf '%s\n' "$dump" | grep -qx 'specialist=specialist' || fail "absent config specialist"
  printf '%s\n' "$dump" | grep -qx 'investigation=investigation' || fail "absent config investigation"
  printf '%s\n' "$dump" | grep -qx 'queue=queue' || fail "absent config queue"
  pass "absent config defaults to bro"
}

test_presets() {
  local home dump
  home="$TMP_ROOT/presets"
  mkdir -p "$home/config"

  printf 'preset=bro\n' > "$home/config/persona"
  dump=$(dump_home "$home") || fail "bro preset"
  printf '%s\n' "$dump" | grep -qx 'lead=Bro' || fail "bro lead"

  printf 'preset=neutral\n' > "$home/config/persona"
  dump=$(dump_home "$home") || fail "neutral preset"
  printf '%s\n' "$dump" | grep -qx 'preset=neutral' || fail "neutral preset name"
  printf '%s\n' "$dump" | grep -qx 'lead=lead' || fail "neutral lead"
  printf '%s\n' "$dump" | grep -qx 'user=user' || fail "neutral user"
  printf '%s\n' "$dump" | grep -qx 'success_opener=' || fail "neutral opener should be empty"

  printf 'preset=dzl\n' > "$home/config/persona"
  dump=$(dump_home "$home") || fail "dzl preset"
  printf '%s\n' "$dump" | grep -qx 'preset=dzl' || fail "dzl preset name"
  printf '%s\n' "$dump" | grep -qx 'lead=DJ' || fail "dzl lead"
  printf '%s\n' "$dump" | grep -qx 'worker=worker' || fail "dzl worker must stay identifiable"
  printf '%s\n' "$dump" | grep -qx 'specialist=specialist' || fail "dzl specialist must stay identifiable"
  printf '%s\n' "$dump" | grep -qx "success_opener=AYO, PR'S HERE" || fail "dzl opener"
  pass "built-in presets resolve"
}

test_overrides_follow_preset() {
  local home dump
  home="$TMP_ROOT/override"
  mkdir -p "$home/config"
  printf 'preset=neutral\nlead=Skip\nuser=pal\n' > "$home/config/persona"
  dump=$(dump_home "$home") || fail "override load"
  printf '%s\n' "$dump" | grep -qx 'preset=neutral' || fail "preset kept"
  printf '%s\n' "$dump" | grep -qx 'lead=Skip' || fail "lead override"
  printf '%s\n' "$dump" | grep -qx 'user=pal' || fail "user override"
  printf '%s\n' "$dump" | grep -qx 'worker=worker' || fail "unoverridden worker"
  pass "overrides apply after preset"
}

test_invalid_explicit_config_errors() {
  local home err
  home="$TMP_ROOT/invalid"
  mkdir -p "$home/config"
  err="$home/err"

  printf 'preset=nope\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "unknown preset succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "unknown preset missing invalid config"

  printf 'lead=Bro\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "missing preset succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "missing preset missing invalid config"

  printf 'preset=bro\nflavor=wild\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "unknown key succeeded"
  fi
  grep -q "unknown key" "$err" || fail "unknown key not reported"

  printf 'preset=bro\nlead=\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "empty value succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "empty value missing invalid config"

  printf 'preset=bro\npreset=dzl\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "duplicate key succeeded"
  fi
  grep -q 'duplicate key' "$err" || fail "duplicate key not reported"

  pass "invalid explicit config errors without fallback"
}

test_injection_and_controls_rejected() {
  local home err
  home="$TMP_ROOT/inject"
  mkdir -p "$home/config"
  err="$home/err"

  # shellcheck disable=SC2016 # intentional literal metacharacters
  printf 'preset=bro\nlead=$(touch pwned)\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "command-substitution lead succeeded"
  fi
  [ ! -e "$home/config/pwned" ] || fail "command substitution was executed"
  [ ! -e "$home/pwned" ] || fail "command substitution was executed in home"
  grep -q 'invalid config' "$err" || fail "injection value not rejected"

  printf 'preset=bro\nlead=Bro\tDJ\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "tab in value succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "tab value not rejected"

  # shellcheck disable=SC2016 # intentional literal metacharacters
  printf 'preset=bro\nlead=ok`id`\n' > "$home/config/persona"
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "backtick lead succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "backtick value not rejected"

  pass "injection and control characters are rejected"
}

test_unicode_role_name_allowed() {
  local home dump
  home="$TMP_ROOT/unicode"
  mkdir -p "$home/config"
  printf 'preset=bro\nlead=Brüder\n' > "$home/config/persona"
  dump=$(dump_home "$home") || fail "unicode lead should load"
  printf '%s\n' "$dump" | grep -qx 'lead=Brüder' || fail "unicode lead not preserved"
  pass "safe unicode role names are allowed"
}

test_two_home_isolation() {
  local rec a b da db
  rec=$(home_pair isolate)
  a=${rec%%|*}
  b=${rec#*|}
  printf 'preset=bro\n' > "$a/config/persona"
  printf 'preset=neutral\n' > "$b/config/persona"
  da=$(dump_home "$a") || fail "home a"
  db=$(dump_home "$b") || fail "home b"
  printf '%s\n' "$da" | grep -qx 'preset=bro' || fail "home a leaked"
  printf '%s\n' "$db" | grep -qx 'preset=neutral' || fail "home b leaked"
  pass "independent FM_HOME values stay isolated"
}

test_primary_authoritative_inheritance() {
  local rec a b
  rec=$(home_pair inherit)
  a=${rec%%|*}
  b=${rec#*|}
  printf 'preset=dzl\nlead=Pauly\n' > "$a/config/persona"
  propagate_inheritable_config "$a/config" "$b/config" \
    || fail "propagate persona"
  cmp -s "$a/config/persona" "$b/config/persona" || fail "persona was not copied"
  [ "$(FM_HOME="$b" FM_CONFIG_OVERRIDE="$b/config" "$PERSONA" --preset)" = dzl ] \
    || fail "inherited persona did not resolve"
  pass "persona inherits primary-authoritatively"
}

test_protocol_headings_intact() {
  local home brief
  home="$TMP_ROOT/brief-headings"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-head-a1 some-proj --mode no-mistakes >/dev/null \
    || fail "fm-brief.sh failed"
  brief="$home/data/brief-head-a1/brief.md"
  grep -F -q "## Captain's intent" "$brief" || fail "Captain's intent heading changed"
  grep -F -q "## Firstmate spec" "$brief" || fail "Firstmate spec heading changed"
  grep -F -q '{FIRSTMATE_SPEC}' "$brief" || fail "FIRSTMATE_SPEC placeholder changed"
  pass "parsed protocol headings stay intact"
}

test_supervision_emits_persona_block() {
  local home out
  home="$TMP_ROOT/supervise"
  mkdir -p "$home/state" "$home/config"
  printf 'preset=dzl\n' > "$home/config/persona"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex) \
    || fail "supervision renderer failed"
  printf '%s\n' "$out" | grep -qx 'PERSONA' || fail "PERSONA heading missing"
  printf '%s\n' "$out" | grep -qx 'product: shuvbro' || fail "product missing"
  printf '%s\n' "$out" | grep -qx 'preset: dzl' || fail "preset missing"
  printf '%s\n' "$out" | grep -qx 'lead: DJ' || fail "lead missing"
  printf '%s\n' "$out" | grep -q 'SUPERVISION OPERATING INSTRUCTIONS' || fail "harness block missing"
  pass "supervision instructions emit the persona block"
}

test_worker_role_uses_lead_label() {
  local home out
  home="$TMP_ROOT/worker-role"
  mkdir -p "$home/config"
  printf 'preset=bro\nlead=Skip\n' > "$home/config/persona"
  fm_persona_reset
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1"; fm_brief_worker_role ship' _ "$ROOT/bin/fm-dod-lib.sh") \
    || fail "worker role failed"
  printf '%s\n' "$out" | grep -q 'Report to Skip' || fail "worker role missing lead label"
  printf '%s\n' "$out" | grep -q 'You are the worker for this task' || fail "ship overlay missing worker label"
  printf '%s\n' "$out" | grep -q 'works on shuvbro itself' || fail "worker role missing product"
  printf '%s\n' "$out" | grep -q 'Do not address dude directly' || fail "worker role should not mandate captain address"
  pass "worker role uses resolved lead label"
}

test_invalid_persona_fails_supervision() {
  local home err out
  home="$TMP_ROOT/supervise-bad"
  mkdir -p "$home/state" "$home/config"
  printf 'preset=nope\n' > "$home/config/persona"
  err="$home/err"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex 2>"$err") && fail "invalid persona supervision succeeded"
  grep -q 'invalid config' "$err" || fail "supervision did not surface invalid config"
  printf '%s\n' "$out" | grep -q 'SUPERVISION OPERATING INSTRUCTIONS' \
    || fail "invalid persona erased safety/supervision instructions"
  printf '%s\n' "$out" | grep -q 'PERSONA CONFIG ERROR' \
    || fail "invalid persona missing repair stanza"
  printf '%s\n' "$out" | grep -q 'Mode: Codex foreground checkpoint' \
    || fail "invalid persona omitted harness protocol"
  pass "invalid persona fails supervision rendering"
}

test_override_before_preset_is_kept() {
  local home dump
  home="$TMP_ROOT/order"
  mkdir -p "$home/config"
  printf 'lead=Skip\npreset=neutral\n' > "$home/config/persona"
  dump=$(dump_home "$home") || fail "override-before-preset should load"
  printf '%s\n' "$dump" | grep -qx 'preset=neutral' || fail "preset lost"
  printf '%s\n' "$dump" | grep -qx 'lead=Skip' || fail "lead override before preset was dropped"
  printf '%s\n' "$dump" | grep -qx 'user=user' || fail "neutral user not applied"
  pass "overrides apply after preset regardless of key order"
}

write_persona_bytes() {  # <path> <perl-string>
  perl -e 'open my $fh, ">:raw", $ARGV[0] or die $!; print $fh $ARGV[1]' -- "$1" "$2"
}

assert_persona_bytes_rejected() {  # <home> <label>
  local home=$1 label=$2 err=$1/err
  if dump_home "$home" >/dev/null 2>"$err"; then
    fail "$label in persona file succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "$label missing invalid config"
  grep -q $'\xEF\xBF\xBD' "$err" && fail "$label normalized to U+FFFD"
  if grep -v '^fm-persona: invalid config:' "$err" | grep -q .; then
    fail "$label leaked extra stderr"
  fi
}

test_nul_and_unicode_format_rejected() {
  local home
  home="$TMP_ROOT/bytes"
  mkdir -p "$home/config"

  perl -e 'open my $fh, ">:raw", $ARGV[0] or die $!; print $fh "preset=bro\nlead=Bro\0DJ\n"' \
    -- "$home/config/persona"
  assert_persona_bytes_rejected "$home" "NUL"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead=Bro"$'\xE2\x80\xAE'"Skip"$'\n'
  assert_persona_bytes_rejected "$home" "bidi U+202E"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead=Bro"$'\xE2\x81\xA3'"DJ"$'\n'
  assert_persona_bytes_rejected "$home" "U+2063"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead=Bro"$'\xC2\x85'"DJ"$'\n'
  assert_persona_bytes_rejected "$home" "U+0085"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead=Bro"$'\xE2\x80\xA8'"DJ"$'\n'
  assert_persona_bytes_rejected "$home" "U+2028"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead=Bro"$'\xE2\x80\xA9'"DJ"$'\n'
  assert_persona_bytes_rejected "$home" "U+2029"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead=Bro"$'\xFF'"DJ"$'\n'
  assert_persona_bytes_rejected "$home" "raw 0xFF"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead="$'\xC2'
  assert_persona_bytes_rejected "$home" "truncated UTF-8 continuation"

  write_persona_bytes "$home/config/persona" "preset=bro"$'\n'"lead="$'\xC2\x20'"DJ"$'\n'
  assert_persona_bytes_rejected "$home" "invalid UTF-8 continuation"
  pass "NUL and Unicode format/control characters are rejected"
}

test_instruction_tail_is_home_specific() {
  local rec a b ta tb te
  rec=$(home_pair tails)
  a=${rec%%|*}
  b=${rec#*|}
  printf 'preset=bro\nlead=Skip\n' > "$a/config/persona"
  printf 'preset=dzl\n' > "$b/config/persona"
  ta=$(FM_HOME="$a" FM_CONFIG_OVERRIDE="$a/config" "$PERSONA" --instruction-tail) \
    || fail "home a instruction-tail"
  tb=$(FM_HOME="$b" FM_CONFIG_OVERRIDE="$b/config" "$PERSONA" --instruction-tail) \
    || fail "home b instruction-tail"
  printf '%s\n' "$ta" | grep -qx 'lead: Skip' || fail "tail a missing Skip"
  printf '%s\n' "$tb" | grep -qx 'lead: DJ' || fail "tail b missing DJ"
  printf '%s\n' "$ta" | grep -q 'lead: DJ' && fail "tail a leaked DJ"
  printf 'preset=nope\n' > "$a/config/persona"
  te=$(FM_HOME="$a" FM_CONFIG_OVERRIDE="$a/config" "$PERSONA" --instruction-tail 2>/dev/null) \
    && fail "invalid instruction-tail succeeded"
  printf '%s\n' "$te" | grep -q 'PERSONA CONFIG ERROR' \
    || fail "invalid instruction-tail missing repair stanza"
  pass "instruction-tail is per-home and carries invalid-config repair"
}

test_ordinary_briefs_use_worker_and_specialist_labels() {
  local home ship scout second err
  home="$TMP_ROOT/roles"
  mkdir -p "$home/data" "$home/config"
  printf 'preset=dzl\nworker=Deckhand\nspecialist=Navigator\nlead=Skip\nuser=pal\n' \
    > "$home/config/persona"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" role-ship-a1 some-proj --mode no-mistakes >/dev/null \
    || fail "ship brief failed"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" role-scout-a1 some-proj --scout >/dev/null \
    || fail "scout brief failed"
  FM_SECONDMATE_CHARTER='scope' FM_HOME="$home" \
    "$ROOT/bin/fm-brief.sh" role-second --secondmate --no-projects >/dev/null \
    || fail "secondmate brief failed"
  ship="$home/data/role-ship-a1/brief.md"
  scout="$home/data/role-scout-a1/brief.md"
  second="$home/data/role-second/brief.md"
  grep -F 'You are the Deckhand: an autonomous worker managed by Skip' "$ship" \
    || fail "ship brief missing Deckhand intro"
  grep -F 'Navigator' "$ship" && fail "ship brief leaked specialist label"
  grep -F 'You are the Navigator: an autonomous worker managed by Skip' "$scout" \
    || fail "scout brief missing Navigator intro"
  grep -F 'Deckhand' "$scout" && fail "scout brief leaked worker label"
  grep -F 'You are the Skip of this isolated home' "$second" \
    || fail "secondmate charter missing lead role"
  grep -F 'Ordinary workers you spawn are the Deckhand' "$second" \
    || fail "secondmate charter missing worker label"
  grep -F 'investigation scouts you spawn are the Navigator' "$second" \
    || fail "secondmate charter missing specialist label"
  grep -F "AYO, PR'S HERE" "$ship" "$scout" "$second" \
    && fail "dzl success opener leaked into a brief"
  grep -F 'success_opener' "$ship" "$scout" "$second" \
    && fail "success_opener field leaked into a brief"
  printf 'preset=nope\n' > "$home/config/persona"
  err="$home/err"
  if FM_HOME="$home" "$ROOT/bin/fm-brief.sh" role-bad-a1 some-proj --mode direct-PR >/dev/null 2>"$err"; then
    fail "invalid persona ship brief succeeded"
  fi
  grep -q 'invalid config' "$err" || fail "invalid persona brief missing error"
  pass "ordinary ship/scout/secondmate briefs use worker and specialist labels"
}

test_launch_overlay_uses_kind_role() {
  local home ship scout
  home="$TMP_ROOT/launch-roles"
  mkdir -p "$home/config"
  printf 'preset=bro\nworker=Deckhand\nspecialist=Navigator\nlead=Skip\nuser=pal\n' \
    > "$home/config/persona"
  ship=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1"; fm_brief_worker_role ship' _ "$ROOT/bin/fm-dod-lib.sh") \
    || fail "ship overlay failed"
  scout=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1"; fm_brief_worker_role scout' _ "$ROOT/bin/fm-dod-lib.sh") \
    || fail "scout overlay failed"
  printf '%s\n' "$ship" | grep -q 'You are the Deckhand for this task' \
    || fail "ship overlay missing Deckhand"
  printf '%s\n' "$ship" | grep -q 'Navigator' && fail "ship overlay leaked Navigator"
  printf '%s\n' "$scout" | grep -q 'You are the Navigator for this task' \
    || fail "scout overlay missing Navigator"
  printf '%s\n' "$scout" | grep -q 'Deckhand' && fail "scout overlay leaked Deckhand"
  printf '%s\n' "$ship" | grep -q 'Report to Skip' || fail "overlay missing lead"
  printf '%s\n' "$ship" | grep -q 'Do not address pal directly' || fail "overlay missing user"
  pass "launch overlay uses worker for ship and specialist for scout"
}

test_session_start_invalid_persona_is_not_complete() {
  local home out err status
  home="$TMP_ROOT/session-bad"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'preset=nope\n' > "$home/config/persona"
  err="$home/err"
  set +e
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_SESSION_START_TIMEOUT=30 \
    "$ROOT/bin/fm-session-start.sh" 2>"$err")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid persona session-start exited 0"
  printf '%s\n' "$out" | grep -q 'SUPERVISION OPERATING INSTRUCTIONS' \
    || fail "invalid persona session-start omitted supervision"
  printf '%s\n' "$out" | grep -q 'PERSONA CONFIG ERROR' \
    || fail "invalid persona session-start omitted repair"
  printf '%s\n' "$out" | grep -q 'not a configured startup' \
    || fail "invalid persona session-start did not refuse dispatch"
  printf '%s\n' "$out" | grep -q 'digest above is complete' \
    && fail "invalid persona session-start claimed complete"
  [ ! -f "$home/state/.session-start-complete" ] \
    || fail "invalid persona session-start wrote a completion marker"
  pass "invalid persona session-start fails closed after printing safety"
}

test_absent_defaults_to_bro
test_presets
test_overrides_follow_preset
test_invalid_explicit_config_errors
test_injection_and_controls_rejected
test_unicode_role_name_allowed
test_two_home_isolation
test_primary_authoritative_inheritance
test_protocol_headings_intact
test_supervision_emits_persona_block
test_worker_role_uses_lead_label
test_invalid_persona_fails_supervision
test_override_before_preset_is_kept
test_nul_and_unicode_format_rejected
test_session_start_invalid_persona_is_not_complete
test_instruction_tail_is_home_specific
test_ordinary_briefs_use_worker_and_specialist_labels
test_launch_overlay_uses_kind_role
