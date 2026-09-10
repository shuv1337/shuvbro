#!/usr/bin/env bash
# fm-persona-lib.sh - presentation-only role names and tone for one home.
#
# Source:  . bin/fm-persona-lib.sh
# CLI:     fm-persona-lib.sh --dump|--block|--instruction-tail|--role <id>|--preset|--idle|--success-opener|--validate
#
# This file is the single owner of config/persona parsing and of the PERSONA
# block session start emits. docs/configuration.md "Persona" owns the operator
# schema. Theme cannot alter safety, approvals, protocols, or success truth.
#
# Never source or eval user content. Values are copied as literals through
# printf. Invalid explicit config returns an error; only an absent file uses
# the built-in bro default. A present file is byte-validated with perl (NUL,
# UTF-8, Unicode Other/control/format, Zl/Zp) before any bash read.
#
# Parse order is independent of key order: collect and validate every line,
# reject duplicates, apply the preset, then apply role overrides.
#
# Permitted role-label characters after UTF-8 decode: any character whose
# Unicode general category is not Other (C*), except ASCII NUL which is
# rejected in the raw bytes, and except LF which is only a record separator.
# `$`, backtick, and backslash are also rejected so labels cannot look like
# shell. Letters, marks, numbers, punctuation (including hyphen and
# apostrophe), symbols, and ordinary space U+0020 are allowed.
#
# shellcheck shell=bash

_FM_PERSONA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_PERSONA_TRACKED_ROOT="$(cd "$_FM_PERSONA_LIB_DIR/.." && pwd)"

FM_PERSONA_PRODUCT="shuvbro"
FM_PERSONA_MAX_LINE=120
FM_PERSONA_MAX_VALUE=64
FM_PERSONA_IDLE_ACK="Nothing needed."
FM_PERSONA_DZL_OPENER="AYO, PR'S HERE"

fm_persona_reset() {
  FM_PERSONA_LOADED=
  FM_PERSONA_ERROR=
  FM_PERSONA_PRESET=
  FM_PERSONA_LEAD=
  FM_PERSONA_USER=
  FM_PERSONA_WORKER=
  FM_PERSONA_SPECIALIST=
  FM_PERSONA_INVESTIGATION=
  FM_PERSONA_QUEUE=
  FM_PERSONA_SUCCESS_OPENER=
  FM_PERSONA_TONE=
  FM_PERSONA_PATH=
}

fm_persona_reset

fm_persona_config_dir() {
  local root home
  root="${FM_ROOT_OVERRIDE:-$_FM_PERSONA_TRACKED_ROOT}"
  home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

fm_persona_config_path() {
  printf '%s/persona\n' "$(fm_persona_config_dir)"
}

fm_persona_error() {
  FM_PERSONA_ERROR=$1
  printf 'fm-persona: %s\n' "$1" >&2
  return 1
}

fm_persona_apply_preset() {
  case "$1" in
    bro)
      FM_PERSONA_LEAD=Bro
      FM_PERSONA_USER=dude
      FM_PERSONA_WORKER=worker
      FM_PERSONA_SPECIALIST=specialist
      FM_PERSONA_INVESTIGATION=investigation
      FM_PERSONA_QUEUE=queue
      FM_PERSONA_SUCCESS_OPENER=
      FM_PERSONA_TONE='informal candid; no mandatory address; no forced slang'
      ;;
    neutral)
      FM_PERSONA_LEAD=lead
      FM_PERSONA_USER=user
      FM_PERSONA_WORKER=worker
      FM_PERSONA_SPECIALIST=specialist
      FM_PERSONA_INVESTIGATION=investigation
      FM_PERSONA_QUEUE=queue
      FM_PERSONA_SUCCESS_OPENER=
      FM_PERSONA_TONE='plain operational; no flavor'
      ;;
    dzl)
      FM_PERSONA_LEAD=DJ
      FM_PERSONA_USER=dude
      FM_PERSONA_WORKER=worker
      FM_PERSONA_SPECIALIST=specialist
      FM_PERSONA_INVESTIGATION=investigation
      FM_PERSONA_QUEUE=queue
      FM_PERSONA_SUCCESS_OPENER=$FM_PERSONA_DZL_OPENER
      FM_PERSONA_TONE='informal candid; optional verified-ready opener only; serious asks stay plain'
      ;;
    *)
      return 1
      ;;
  esac
  FM_PERSONA_PRESET=$1
  return 0
}

fm_persona_valid_role_id() {
  case "$1" in
    lead|user|worker|specialist|investigation|queue) return 0 ;;
    *) return 1 ;;
  esac
}

fm_persona_valid_value() {
  local value=$1
  [ -n "$value" ] || return 1
  [ "${#value}" -le "$FM_PERSONA_MAX_VALUE" ] || return 1
  case "$value" in
    *$'\n'*|*$'\r'*) return 1 ;;
    *\$*|*\`*) return 1 ;;
  esac
  case "$value" in
    *\\*) return 1 ;;
  esac
  return 0
}

fm_persona_set_role() {
  case "$1" in
    lead) FM_PERSONA_LEAD=$2 ;;
    user) FM_PERSONA_USER=$2 ;;
    worker) FM_PERSONA_WORKER=$2 ;;
    specialist) FM_PERSONA_SPECIALIST=$2 ;;
    investigation) FM_PERSONA_INVESTIGATION=$2 ;;
    queue) FM_PERSONA_QUEUE=$2 ;;
    *) return 1 ;;
  esac
}

# Reject NUL before bash read, invalid UTF-8, Unicode Other (C*), and
# Unicode line/paragraph separators (Zl/Zp, including U+2028/U+2029).
# Uses perl, already required by other bin/ scripts (timeout, inherit).
# Not a new bootstrap tool. A present file fails closed if perl is missing.
fm_persona_validate_file_bytes() {
  local path=$1 rc
  command -v perl >/dev/null 2>&1 || {
    fm_persona_error "invalid config: perl is required to validate a present $path"
    return 1
  }
  perl - "$path" <<'PL'
use strict;
use warnings;
use Encode qw(decode FB_CROAK);
my $path = $ARGV[0];
open my $rawfh, "<:raw", $path or exit 5;
my $bytes = do { local $/; <$rawfh> };
close $rawfh;
$bytes = "" unless defined $bytes;
exit 2 if index($bytes, "\0") >= 0;
my $text;
eval {
  local $SIG{__WARN__} = sub { };
  $text = decode("UTF-8", $bytes, FB_CROAK);
  1;
} or exit 3;
for my $ch (split //, $text) {
  next if $ch eq "\n";
  exit 4 if $ch =~ /\p{Cc}|\p{Cf}|\p{Cs}|\p{Co}|\p{Cn}|\p{Zl}|\p{Zp}/;
}
exit 0;
PL
  rc=$?
  case "$rc" in
    0) return 0 ;;
    2) fm_persona_error "invalid config: NUL byte in $path" ;;
    3) fm_persona_error "invalid config: not valid UTF-8 in $path" ;;
    4) fm_persona_error "invalid config: control, format, or line/paragraph separator in $path" ;;
    *) fm_persona_error "invalid config: cannot byte-validate $path" ;;
  esac
  return 1
}

fm_persona_parse_file() {
  local path=$1 line key value
  local seen_preset=0 seen_lead=0 seen_user=0 seen_worker=0
  local seen_specialist=0 seen_investigation=0 seen_queue=0
  local got_preset='' ov_lead='' ov_user='' ov_worker='' ov_specialist=''
  local ov_investigation='' ov_queue=''

  fm_persona_validate_file_bytes "$path" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    [ "${#line}" -le "$FM_PERSONA_MAX_LINE" ] || {
      fm_persona_error "invalid config: line exceeds $FM_PERSONA_MAX_LINE characters in $path"
      return 1
    }
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        fm_persona_error "invalid config: expected key=value in $path"
        return 1
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      preset|lead|user|worker|specialist|investigation|queue) ;;
      *)
        fm_persona_error "invalid config: unknown key '$key' in $path"
        return 1
        ;;
    esac
    fm_persona_valid_value "$value" || {
      fm_persona_error "invalid config: bad value for '$key' in $path"
      return 1
    }
    case "$key" in
      preset)
        [ "$seen_preset" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'preset' in $path"
          return 1
        }
        seen_preset=1
        got_preset=$value
        ;;
      lead)
        [ "$seen_lead" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'lead' in $path"
          return 1
        }
        seen_lead=1
        ov_lead=$value
        ;;
      user)
        [ "$seen_user" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'user' in $path"
          return 1
        }
        seen_user=1
        ov_user=$value
        ;;
      worker)
        [ "$seen_worker" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'worker' in $path"
          return 1
        }
        seen_worker=1
        ov_worker=$value
        ;;
      specialist)
        [ "$seen_specialist" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'specialist' in $path"
          return 1
        }
        seen_specialist=1
        ov_specialist=$value
        ;;
      investigation)
        [ "$seen_investigation" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'investigation' in $path"
          return 1
        }
        seen_investigation=1
        ov_investigation=$value
        ;;
      queue)
        [ "$seen_queue" -eq 0 ] || {
          fm_persona_error "invalid config: duplicate key 'queue' in $path"
          return 1
        }
        seen_queue=1
        ov_queue=$value
        ;;
    esac
  done < "$path"

  [ "$seen_preset" -eq 1 ] || {
    fm_persona_error "invalid config: missing preset in $path"
    return 1
  }
  fm_persona_apply_preset "$got_preset" || {
    fm_persona_error "invalid config: unknown preset '$got_preset' in $path"
    return 1
  }
  [ "$seen_lead" -eq 1 ] && fm_persona_set_role lead "$ov_lead"
  [ "$seen_user" -eq 1 ] && fm_persona_set_role user "$ov_user"
  [ "$seen_worker" -eq 1 ] && fm_persona_set_role worker "$ov_worker"
  [ "$seen_specialist" -eq 1 ] && fm_persona_set_role specialist "$ov_specialist"
  [ "$seen_investigation" -eq 1 ] && fm_persona_set_role investigation "$ov_investigation"
  [ "$seen_queue" -eq 1 ] && fm_persona_set_role queue "$ov_queue"
  return 0
}

fm_persona_load() {
  local path

  if [ "$FM_PERSONA_LOADED" = 1 ]; then
    return 0
  fi
  if [ "$FM_PERSONA_LOADED" = 0 ]; then
    [ -n "$FM_PERSONA_ERROR" ] && printf 'fm-persona: %s\n' "$FM_PERSONA_ERROR" >&2
    return 1
  fi

  path=$(fm_persona_config_path)
  FM_PERSONA_PATH=$path

  if [ ! -e "$path" ]; then
    fm_persona_apply_preset bro
    FM_PERSONA_LOADED=1
    return 0
  fi
  if [ -d "$path" ] || [ ! -f "$path" ] || [ ! -r "$path" ]; then
    FM_PERSONA_LOADED=0
    fm_persona_error "invalid config: $path is not a readable regular file"
    return 1
  fi

  if ! fm_persona_parse_file "$path"; then
    FM_PERSONA_LOADED=0
    return 1
  fi
  FM_PERSONA_LOADED=1
  return 0
}

fm_persona_repair_stanza() {
  local path
  path=$(fm_persona_config_path)
  printf 'PERSONA CONFIG ERROR\n'
  printf 'product: %s\n' "$FM_PERSONA_PRODUCT"
  printf 'config: %s\n' "$path"
  printf 'Presentation names are unavailable because config/persona is present and invalid.\n'
  printf 'Safety, approvals, protocols, and supervision instructions are unchanged.\n'
  printf 'This is not a configured startup. Do not dispatch work until persona config is valid.\n'
  printf 'Fix the file, or remove it to select the documented bro default.\n'
  printf 'Schema: docs/configuration.md "Persona". Check: bin/fm-persona-lib.sh --validate\n'
  if [ -n "$FM_PERSONA_ERROR" ]; then
    printf 'detail: %s\n' "$FM_PERSONA_ERROR"
  fi
}

fm_persona_role() {
  fm_persona_load || return 1
  fm_persona_valid_role_id "$1" || {
    fm_persona_error "unknown role id '$1'"
    return 1
  }
  case "$1" in
    lead) printf '%s\n' "$FM_PERSONA_LEAD" ;;
    user) printf '%s\n' "$FM_PERSONA_USER" ;;
    worker) printf '%s\n' "$FM_PERSONA_WORKER" ;;
    specialist) printf '%s\n' "$FM_PERSONA_SPECIALIST" ;;
    investigation) printf '%s\n' "$FM_PERSONA_INVESTIGATION" ;;
    queue) printf '%s\n' "$FM_PERSONA_QUEUE" ;;
  esac
}

fm_persona_preset() {
  fm_persona_load || return 1
  printf '%s\n' "$FM_PERSONA_PRESET"
}

fm_persona_idle() {
  fm_persona_load || return 1
  printf '%s\n' "$FM_PERSONA_IDLE_ACK"
}

fm_persona_success_opener() {
  fm_persona_load || return 1
  printf '%s\n' "$FM_PERSONA_SUCCESS_OPENER"
}

fm_persona_opener_display() {
  if [ -n "$FM_PERSONA_SUCCESS_OPENER" ]; then
    printf '%s\n' "$FM_PERSONA_SUCCESS_OPENER"
  else
    printf '%s\n' '(none)'
  fi
}

fm_persona_block() {
  fm_persona_load || return 1
  printf 'PERSONA\n'
  printf 'product: %s\n' "$FM_PERSONA_PRODUCT"
  printf 'preset: %s\n' "$FM_PERSONA_PRESET"
  printf 'lead: %s\n' "$FM_PERSONA_LEAD"
  printf 'user: %s\n' "$FM_PERSONA_USER"
  printf 'worker: %s\n' "$FM_PERSONA_WORKER"
  printf 'specialist: %s\n' "$FM_PERSONA_SPECIALIST"
  printf 'investigation: %s\n' "$FM_PERSONA_INVESTIGATION"
  printf 'queue: %s\n' "$FM_PERSONA_QUEUE"
  printf 'idle_acknowledgement: %s\n' "$FM_PERSONA_IDLE_ACK"
  printf 'success_opener: %s\n' "$(fm_persona_opener_display)"
  printf 'tone: %s\n' "$FM_PERSONA_TONE"
  printf 'flavor_rule: role display labels may appear in generated instructions; slang, catchphrases, and seasoning never belong in briefs, commits, PRs, reviews, or machine protocol\n'
  printf 'ready_rule: success opener only for a verified ready PR; never pending or failing work\n'
  printf 'serious_rule: failures, security questions, and approval asks stay plain\n'
  printf 'AGENTS.md uses operational role ids and defers display names and tone to this block.\n'
}

# Always print a tail block for wake/context insertion. Exit 1 when the
# present file is invalid so callers can fail closed without omitting safety.
fm_persona_instruction_tail() {
  if fm_persona_block; then
    return 0
  fi
  fm_persona_repair_stanza
  return 1
}

fm_persona_dump() {
  fm_persona_load || return 1
  printf 'config=%s\n' "$FM_PERSONA_PATH"
  printf 'preset=%s\n' "$FM_PERSONA_PRESET"
  printf 'lead=%s\n' "$FM_PERSONA_LEAD"
  printf 'user=%s\n' "$FM_PERSONA_USER"
  printf 'worker=%s\n' "$FM_PERSONA_WORKER"
  printf 'specialist=%s\n' "$FM_PERSONA_SPECIALIST"
  printf 'investigation=%s\n' "$FM_PERSONA_INVESTIGATION"
  printf 'queue=%s\n' "$FM_PERSONA_QUEUE"
  printf 'idle=%s\n' "$FM_PERSONA_IDLE_ACK"
  printf 'success_opener=%s\n' "$FM_PERSONA_SUCCESS_OPENER"
}

fm_persona_cli() {
  case "${1:-}" in
    --dump) fm_persona_dump ;;
    --block) fm_persona_block ;;
    --instruction-tail) fm_persona_instruction_tail ;;
    --preset) fm_persona_preset ;;
    --idle) fm_persona_idle ;;
    --success-opener) fm_persona_success_opener ;;
    --validate) fm_persona_load ;;
    --role)
      [ -n "${2:-}" ] || {
        printf 'fm-persona: --role requires lead|user|worker|specialist|investigation|queue\n' >&2
        return 2
      }
      fm_persona_role "$2"
      ;;
    -h|--help)
      cat <<'EOF'
Usage: fm-persona-lib.sh --dump|--block|--instruction-tail|--role <id>|--preset|--idle|--success-opener|--validate
EOF
      ;;
    *)
      printf 'fm-persona: unknown argument %s\n' "${1:-}" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_persona_cli "$@"
fi
