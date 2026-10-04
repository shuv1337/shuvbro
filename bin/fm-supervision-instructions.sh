#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$REPO_ROOT}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

# shellcheck source=bin/fm-persona-lib.sh
. "$SCRIPT_DIR/fm-persona-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

HARNESS=
READ_ONLY=0
AFK=0
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
fi

case "$HARNESS" in
  claude|codex|opencode|opencode-v2|pi|grok|cursor|omp) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"

# Native V2 supervision requires a proven exact activation, regardless of git
# checkout shape. An ordinary unactivated client has no watcher owner.
V2_INACTIVE=
if [ "$HARNESS" = opencode-v2 ]; then
  if fm_root_is_secondmate_home "$FM_ROOT" \
    || { [ "$FM_HOME" != "$FM_ROOT" ] && fm_root_is_secondmate_home "$FM_HOME"; }; then
    V2_INACTIVE=secondmate
  elif ! fm_primary_v2_scope_matches "$FM_ROOT" "$STATE"; then
    V2_INACTIVE=checkout
  fi
  [ -z "$V2_INACTIVE" ] || SNIPPET="$DOC_DIR/unknown.md"
fi

checkpoint_seconds=${FM_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
pi_turnend_ext="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
omp_ext="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
omp_turnend_ext="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//__FM_PI_EXT__/$pi_ext}
    line=${line//__FM_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__FM_OMP_EXT__/$omp_ext}
    line=${line//__FM_OMP_TURNEND_EXT__/$omp_turnend_ext}
    line=${line//__FM_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__FM_X_MODE_ENV__/$x_mode_env}
    printf '%s\n' "$line"
  done < "$SNIPPET"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    printf '%s\n' 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    omp)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool fm_watch_arm_omp, or restart omp inside this home so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' auto-load from .omp/extensions/ (use -e with both paths only when starting omp from another directory).'
      ;;
    opencode-v2)
      if [ "$V2_INACTIVE" = secondmate ]; then
        printf '%s%s\n' "$prefix" 'automatic OpenCode V2 supervision is inactive in a secondmate home; run this secondmate on a qualified harness, or keep the generic bounded foreground wait over bin/fm-watch.sh, never shell &.'
      elif [ -n "$V2_INACTIVE" ]; then
        printf '%s%s\n' "$prefix" 'automatic OpenCode V2 supervision is inactive without exact activation; relaunch the lead with bin/fm-opencode-v2-lead.sh (or bin/fm-opencode-v2-primary.sh --session ID --native-binary PATH) on the execution host, or keep the generic bounded foreground wait over bin/fm-watch.sh, never shell &.'
      else
        printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      fi
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.'
      ;;
    cursor)
      printf '%s%s\n' "$prefix" 'watcher supervision is owned by the stop-hook park; inspect the hook registration and watcher startup path before ending the turn.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      printf '%s\n' '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    omp)
      printf '%s\n' '- Ordinary wake: the omp extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode-v2)
      if [ -n "$V2_INACTIVE" ]; then
        printf '%s\n' '- Ordinary wake: automatic OpenCode V2 supervision is inactive in this checkout; no plugin owns watcher continuity here, so follow the fallback below.'
      else
        printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      fi
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s\n' '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
      ;;
    cursor)
      printf '%s\n' '- Ordinary wake: the stop-hook park (bin/fm-turnend-guard-cursor.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

v2_inactive_notice() {
  [ -n "$V2_INACTIVE" ] || return 0
  printf '%s\n' 'OpenCode V2 automatic supervision: INACTIVE in this checkout.'
  printf '%s\n' 'No exact native TUI ownership proof is available here, so no plugin owns automatic watcher continuity.'
  if [ "$V2_INACTIVE" = secondmate ]; then
    printf '%s\n' 'This checkout is a secondmate home, and OpenCode V2 secondmates are not qualified.'
    printf '%s\n' 'Supported: run this secondmate on a qualified harness.'
  else
    printf '%s\n' 'Activate the exact lead on its execution host by relaunching it with bin/fm-opencode-v2-lead.sh, which resolves the session and native executable for bin/fm-opencode-v2-primary.sh --session ID --native-binary PATH.'
    printf '%s\n' 'Plain and linked copies, including external homes, both require this explicit activation; opening a tab never transfers ownership.'
  fi
  printf '%s\n' 'Until then this session has no verified wake adapter, so the unknown-harness fallback below applies.'
  printf '\n'
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================================================================================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  printf '%s\n' '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
else
  printf '%s\n' '- Away mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
ordinary_wake_line
printf '\n'
v2_inactive_notice
render_snippet
printf '\n'
PERSONA_RC=0
if ! fm_persona_instruction_tail; then
  PERSONA_RC=2
fi
printf '\n'
exit "$PERSONA_RC"
