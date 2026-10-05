#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs its file set with ShellCheck's default severity, extended analysis,
# ambient configuration disabled, and one exact ShellCheck version. CI and
# no-mistakes share this owner; no-mistakes invokes it with no arguments to select
# the context-appropriate rule set without duplicating lint configuration.
# The explicit --fast mode is local-only and disables ShellCheck's extended
# dataflow analysis while preserving ordinary shell lint checks and source
# following. CI, main, and merge-base-less runs keep --norc --external-sources
# with full dataflow over the whole canonical set. An ordinary local branch
# (changed-file mode, including the no-mistakes lint step) drops
# --external-sources, keeps dataflow, and excludes SC1091, SC2034, SC2153,
# and SC2329, the codes that need library context. Those codes still run in
# CI over the whole set. Explicit paths keep --external-sources with the
# selected dataflow mode.
# Tests stop source analysis at imported production modules because CI analyzes
# every production shell separately as a canonical, source-aware root.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# With no explicit paths, the file set and source-following posture depend
# on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with
#     --external-sources and full dataflow. This is what CI always runs, so
#     CI coverage never depends on a local diff.
#   - Otherwise (an ordinary local branch with a real merge-base) it lints
#     only the canonical-set files changed since that merge-base, including
#     uncommitted local edits, via plain local `git diff` (no network, no
#     `gh`). That local pass drops --external-sources and excludes SC1091,
#     SC2034, SC2153, and SC2329. A branch with zero matching changed files
#     skips ShellCheck and prints a "no changed lint targets" note, then
#     still runs the backend-purity check and validates workflows.
# Explicit paths always bypass this file-set selection and lint exactly the
# given paths, matching the same config, without the workflow YAML check.
# Explicit core bin/ and bin/backends/ scripts still receive the
# backend-purity check. The backend-purity check rejects direct Beads CLI
# invocations in the core bin/ and bin/backends/ scripts so every configured
# backlog backend follows the same tasks-axi lifecycle path.
#
# Canonical lint keeps two stable logical shards. Local changed-file mode, which
# does not follow sources, runs those shards on two workers. Full source-following
# analysis uses one worker unless --jobs or FM_LINT_JOBS selects two. One
# ShellCheck process follows every sourced file for its root, and a second
# concurrent process exhausts a hosted runner: the CI lint step is signaled and
# exits 143 before any finding is printed.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. Each root is
# its own ShellCheck process by default, including with source following.
# FM_LINT_ONE_FILE=0 explicitly restores one invocation per shard.
# FM_LINT_JOBS=1 runs the same shards serially with byte-identical diagnostics
# and exit selection. FM_LINT_JOBS=2 keeps that output and runs both shards at once.
# --shard i/N selects one duration-balanced partition of the full canonical set,
# even on a local branch. CI runs each partition on a separate hosted runner.
# This mode requires one worker, one root per process, and full source-following
# dataflow; --fast, explicit paths, --jobs 2, and FM_LINT_ONE_FILE=0 are refused.
# --list-files composes with --shard to expose the exact partition without tools.
# Measured root-duration hints below affect only balance; new roots fall back to
# a conservative byte-size weight. Workflow lint and backend purity still run
# in every partition.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override bounded worker count
#   fm-lint.sh --shard <i/N>           select a full-corpus CI partition (1-based)
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
# Cross-file codes that need --external-sources. Local changed-file mode
# cannot judge them, so they stay CI-only.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output invocation_rc rc=0
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    shellcheck_args=(--norc)
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      shellcheck_args+=(--external-sources)
    fi
    if [ -n "${FM_LINT_INTERNAL_EXCLUDE:-}" ]; then
      shellcheck_args+=(--exclude="$FM_LINT_INTERNAL_EXCLUDE")
    fi
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    : > "$output.out"
    # An explicit opt-out retains batched source-following analysis.
    # Default per-root analysis bounds peak RSS to one root's graph.
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ] \
      && [ "${FM_LINT_INTERNAL_ONE_FILE:-0}" -eq 0 ]; then
      "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "${roots[@]}" >> "$output.out" 2>&1 &
      FM_LINT_WORKER_SHELLCHECK_PID=$!
      wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
      FM_LINT_WORKER_SHELLCHECK_PID=
    else
      for path in "${roots[@]}"; do
        invocation_rc=0
        "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "$path" >> "$output.out" 2>&1 &
        FM_LINT_WORKER_SHELLCHECK_PID=$!
        wait "$FM_LINT_WORKER_SHELLCHECK_PID" || invocation_rc=$?
        FM_LINT_WORKER_SHELLCHECK_PID=
        if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
          rc=$invocation_rc
        fi
      done
    fi
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  local findings path canonical
  local -a purity_roots
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  findings=$(LC_ALL=C awk '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

JOBS_EXPLICIT=0
if [ -n "${FM_LINT_JOBS:-}" ]; then
  JOBS=$FM_LINT_JOBS
  JOBS_EXPLICIT=1
else
  JOBS=2
fi
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
CI_SHARD=
CI_SHARD_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --shard)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --shard requires i/N.\n' >&2; exit 2; }
      CI_SHARD=$2
      CI_SHARD_SET=1
      shift 2
      ;;
    --shard=*)
      CI_SHARD=${1#*=}
      CI_SHARD_SET=1
      shift
      ;;
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

if [ -n "${FM_LINT_ONE_FILE+x}" ]; then
  ONE_FILE=$FM_LINT_ONE_FILE
else
  ONE_FILE=1
fi
case "$ONE_FILE" in
  0|1) ;;
  *) printf 'fm-lint.sh: FM_LINT_ONE_FILE must be 0 or 1, got %s.\n' "$ONE_FILE" >&2; exit 2 ;;
esac

if [ "$CI_SHARD_SET" -eq 1 ]; then
  if [[ ! "$CI_SHARD" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] || [ "${#CI_SHARD}" -gt 5 ]; then
    printf 'fm-lint.sh: --shard must be i/N with 1 <= i <= N <= 64.\n' >&2
    exit 2
  fi
  CI_SHARD_INDEX=${CI_SHARD%/*}
  CI_SHARD_COUNT=${CI_SHARD#*/}
  if [ "$CI_SHARD_INDEX" -gt "$CI_SHARD_COUNT" ] || [ "$CI_SHARD_COUNT" -gt 64 ]; then
    printf 'fm-lint.sh: --shard must be i/N with 1 <= i <= N <= 64.\n' >&2
    exit 2
  fi
  if [ "$FAST" -eq 1 ] || [ "$#" -gt 0 ] || { [ "$JOBS" -eq 2 ] && [ "$JOBS_EXPLICIT" -eq 1 ]; } \
    || [ "$ONE_FILE" -eq 0 ]; then
    printf 'fm-lint.sh: --shard requires full analysis, no explicit paths, one worker, and one root per process.\n' >&2
    exit 2
  fi
  JOBS=1
fi

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# Full-analysis root timings measured with the pinned ShellCheck. These are
# balance hints only; unseen roots get at least 1000 ms or bytes/10, whichever
# is larger. Refresh with the same per-root --norc --external-sources command,
# not reduced-analysis results. The shipping PR retains measurement evidence.
fm_lint_ci_weight_hints() {
  cat <<'EOF'
bin/backends/cmux.sh 733
bin/backends/herdr.sh 5144
bin/backends/orca.sh 575
bin/backends/tmux.sh 1337
bin/backends/zellij.sh 826
bin/fm-afk-contract.sh 1443
bin/fm-afk-launch.sh 5405
bin/fm-afk-return.sh 5849
bin/fm-afk-start.sh 2529
bin/fm-arm-pretool-check.sh 40
bin/fm-backend-hometag-lib.sh 14
bin/fm-backend.sh 283
bin/fm-backlog-handoff.sh 27974
bin/fm-backlog-receive.sh 2562
bin/fm-backlog-transition-lib.sh 475
bin/fm-bearings-board.sh 92
bin/fm-bearings-snapshot.sh 164
bin/fm-board.sh 2937
bin/fm-bootstrap.sh 11269
bin/fm-branch-outcome.sh 3936
bin/fm-branch-prompt.sh 7
bin/fm-brief.sh 1591
bin/fm-busy-event.sh 363
bin/fm-busy-lib.sh 239
bin/fm-captain-hold.sh 6211
bin/fm-cd-pretool-check.sh 37
bin/fm-check-lib.sh 36
bin/fm-check-register.sh 782
bin/fm-check-unregister.sh 763
bin/fm-classify-lib.sh 876
bin/fm-claude-stop-autoarm.sh 2905
bin/fm-claude-trust.sh 44
bin/fm-composer-lib.sh 458
bin/fm-config-inherit-lib.sh 695
bin/fm-config-push.sh 4493
bin/fm-control-lib.sh 59
bin/fm-control.sh 4812
bin/fm-crew-state.sh 3202
bin/fm-cursor-lib.sh 57
bin/fm-decision-hold.sh 90
bin/fm-doc-audience-check.sh 8
bin/fm-dod-lib.sh 222
bin/fm-ensure-agents-md.sh 48
bin/fm-extension.sh 7
bin/fm-ff-lib.sh 300
bin/fm-fleet-snapshot.sh 2801
bin/fm-fleet-sync.sh 233
bin/fm-fleet-view.sh 9
bin/fm-fork-boundary-check.sh 75
bin/fm-gate-refuse-lib.sh 12
bin/fm-gemini-lib.sh 19
bin/fm-guard.sh 2487
bin/fm-harness.sh 234
bin/fm-herdr-ci-cleanup.sh 26
bin/fm-herdr-lab.sh 115
bin/fm-herdr-session-cleanup.sh 4126
bin/fm-home-seed.sh 3354
bin/fm-home-summary-refresh.sh 2657
bin/fm-hook-host-lib.sh 6
bin/fm-inactive-reconcile.sh 4366
bin/fm-inbox.sh 105
bin/fm-install-actionlint.sh 19
bin/fm-install-herdr.sh 21
bin/fm-install-runner-tools.sh 47
bin/fm-install-shellcheck.sh 20
bin/fm-install-treehouse.sh 24
bin/fm-kimi-turnend-hook.sh 15
bin/fm-landed-lib.sh 5
bin/fm-lease-lib.sh 40
bin/fm-lease.sh 2646
bin/fm-line-cap-lib.sh 8
bin/fm-lint-workflows.sh 27
bin/fm-lint.sh 322
bin/fm-lock-lib.sh 25
bin/fm-lock.sh 2874
bin/fm-mail-check.sh 1078
bin/fm-mail.sh 5740
bin/fm-marker-lib.sh 69
bin/fm-merge-local.sh 4076
bin/fm-merge-outcome-lib.sh 3495
bin/fm-nm-run-lib.sh 83
bin/fm-on.sh 197
bin/fm-opencode-v2-launch.sh 53
bin/fm-opencode-v2-lead.sh 74
bin/fm-opencode-v2-primary.sh 24
bin/fm-operational-input.sh 62
bin/fm-parent-channel-lib.sh 46
bin/fm-peek.sh 347
bin/fm-pending-reply-lib.sh 14562
bin/fm-persona-lib.sh 122
bin/fm-pr-check.sh 3598
bin/fm-pr-lib.sh 670
bin/fm-pr-merge.sh 8687
bin/fm-pr-poll.sh 31
bin/fm-primary-scope-lib.sh 19
bin/fm-procevent-lavish.sh 4328
bin/fm-procevent-lib.sh 589
bin/fm-procevent-quota.sh 4364
bin/fm-procevent-remote-reply.sh 21782
bin/fm-procevent-when.sh 4804
bin/fm-procevent.sh 5222
bin/fm-project-mode.sh 13
bin/fm-project-origin-lib.sh 28
bin/fm-promote.sh 9997
bin/fm-public-followup-collect.sh 4609
bin/fm-public-followup-emit.sh 4600
bin/fm-public-followup-lib.sh 4434
bin/fm-public-followup.sh 6306
bin/fm-push-transition-lib.sh 4372
bin/fm-quota-axi-lib.sh 18
bin/fm-quota-choose.sh 139
bin/fm-remote-delta-read.sh 81
bin/fm-remote-doctor.sh 2052
bin/fm-remote-entrypoint.sh 836
bin/fm-remote-file.sh 2696
bin/fm-remote-herdr-guard.sh 87
bin/fm-remote-herdr-owner-lib.sh 50
bin/fm-remote-home-provision.sh 2712
bin/fm-remote-home-seed.sh 2925
bin/fm-remote-inherit-push.sh 985
bin/fm-remote-inherit.sh 3422
bin/fm-remote-job-lib.sh 659
bin/fm-remote-job-reap-orphans.sh 802
bin/fm-remote-job-worker.sh 1545
bin/fm-remote-readiness-lib.sh 11
bin/fm-remote-secondmate-control.sh 16784
bin/fm-review-diff.sh 61
bin/fm-secondmate-charter-lib.sh 8
bin/fm-secondmate-nudge-lib.sh 33
bin/fm-secondmate-parent-lib.sh 16
bin/fm-secondmate-reconcile.sh 2665
bin/fm-secondmate-registry-lib.sh 106
bin/fm-secondmate-report.sh 15632
bin/fm-secondmate-restart-lib.sh 420
bin/fm-secondmate-restart.sh 14970
bin/fm-send.sh 24412
bin/fm-session-lock-lib.sh 196
bin/fm-session-start.sh 8901
bin/fm-sessionstart-cursor.sh 9
bin/fm-sessionstart-nudge.sh 129
bin/fm-sessionstart-run.sh 319
bin/fm-sharkctl-guard.sh 17
bin/fm-shuvcode-lib.sh 44
bin/fm-spawn.sh 11692
bin/fm-startup-memory-budget-lib.sh 55
bin/fm-startup-memory-budget.sh 84
bin/fm-startup-network.sh 3056
bin/fm-stow-cascade.sh 936
bin/fm-subagent-pretool-check.sh 53
bin/fm-supervise-daemon.sh 8901
bin/fm-supervision-instructions.sh 256
bin/fm-supervision-lib.sh 23
bin/fm-supervisor-target-lib.sh 9
bin/fm-tangle-lib.sh 14
bin/fm-task-inbox-lib.sh 130
bin/fm-tasks-axi-lib.sh 55
bin/fm-teardown.sh 33583
bin/fm-test-isolation-proof.sh 160
bin/fm-test-run.sh 941
bin/fm-timeout-lib.sh 47
bin/fm-timing-lib.sh 27
bin/fm-tmux-lib.sh 724
bin/fm-tool-update-check.sh 1224
bin/fm-trace-context-lib.sh 44
bin/fm-transition-lib.sh 13
bin/fm-turnend-guard-cursor.sh 3006
bin/fm-turnend-guard-grok.sh 92
bin/fm-turnend-guard.sh 2580
bin/fm-update.sh 901
bin/fm-vendor-auth-probe.sh 66
bin/fm-wake-drain.sh 4381
bin/fm-wake-grant.sh 2360
bin/fm-wake-lib.sh 2163
bin/fm-watch-arm.sh 2514
bin/fm-watch-checkpoint.sh 23
bin/fm-watch.sh 23759
bin/fm-x-dismiss.sh 1316
bin/fm-x-followup.sh 3986
bin/fm-x-lib.sh 1116
bin/fm-x-link.sh 5219
bin/fm-x-poll.sh 4764
bin/fm-x-reply.sh 1387
tests/cmux-test-safety.sh 12
tests/fixtures.sh 190
tests/fm-afk-contract.test.sh 482
tests/fm-afk-inject-e2e.test.sh 74
tests/fm-afk-inject-herdr-e2e.test.sh 135
tests/fm-afk-launch.test.sh 470
tests/fm-afk-pi-herdr-return-e2e.test.sh 319
tests/fm-afk-return.test.sh 561
tests/fm-arm-pretool-check.test.sh 356
tests/fm-ask-user-authority.test.sh 170
tests/fm-backend-autodetect-smoke.test.sh 46
tests/fm-backend-cmux-smoke.test.sh 60
tests/fm-backend-cmux.test.sh 2794
tests/fm-backend-herdr-eventwait-smoke.test.sh 51
tests/fm-backend-herdr-focus-flash-e2e.test.sh 137
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh 213
tests/fm-backend-herdr-presentation-e2e.test.sh 1242
tests/fm-backend-herdr-prune-safety-e2e.test.sh 49
tests/fm-backend-herdr-respawn-idem-e2e.test.sh 41
tests/fm-backend-herdr-smoke.test.sh 107
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh 79
tests/fm-backend-herdr.test.sh 18789
tests/fm-backend-orca.test.sh 904
tests/fm-backend-tmux-smoke.test.sh 50
tests/fm-backend-zellij-smoke.test.sh 70
tests/fm-backend-zellij.test.sh 3176
tests/fm-backend.test.sh 693
tests/fm-backlog-atomicity.test.sh 3437
tests/fm-backlog-handoff.test.sh 723
tests/fm-bearings-board-lavish-live-e2e.test.sh 203
tests/fm-bearings-board-render.test.sh 217
tests/fm-bearings-board.test.sh 472
tests/fm-bearings-snapshot.test.sh 1664
tests/fm-board.test.sh 774
tests/fm-bootstrap-network-parallel.test.sh 256
tests/fm-bootstrap.test.sh 652
tests/fm-branch-supervision.test.sh 649
tests/fm-brief.test.sh 510
tests/fm-busy-adapter-wiring.test.sh 545
tests/fm-busy-state.test.sh 399
tests/fm-calm-pi-extension.test.sh 1192
tests/fm-captain-hold-lifecycle.test.sh 2246
tests/fm-cd-pretool-check.test.sh 362
tests/fm-check-unregister.test.sh 271
tests/fm-classify-corr-token.test.sh 461
tests/fm-classify-decision-key.test.sh 1405
tests/fm-claude-stop-autoarm-live-e2e.test.sh 220
tests/fm-claude-stop-autoarm.test.sh 790
tests/fm-claude-trust.test.sh 422
tests/fm-cmux-claude-composer-live-e2e.test.sh 575
tests/fm-codex-continuity-live-e2e.test.sh 183
tests/fm-composer-ghost.test.sh 442
tests/fm-composer-lib.test.sh 455
tests/fm-composer-matrix-live-e2e.test.sh 257
tests/fm-control-herdr-smoke.test.sh 42
tests/fm-control-herdr-v2-live-e2e.test.sh 734
tests/fm-control-relaunch.test.sh 7242
tests/fm-control.test.sh 3532
tests/fm-crew-state.test.sh 1189
tests/fm-cursor-harness.test.sh 2400
tests/fm-cursor-primary-live-e2e.test.sh 240
tests/fm-cursor-primary.test.sh 462
tests/fm-daemon.test.sh 12627
tests/fm-documentation-audiences.test.sh 185
tests/fm-ensure-agents-md.test.sh 388
tests/fm-extension-binding.test.sh 3929
tests/fm-fleet-snapshot-view.test.sh 496
tests/fm-fleet-sync.test.sh 439
tests/fm-fork-boundary.test.sh 217
tests/fm-gate-refuse.test.sh 372
tests/fm-gemini-harness.test.sh 362
tests/fm-gitignore-config.test.sh 20
tests/fm-gotmp.test.sh 55
tests/fm-grok-continuity-live-e2e.test.sh 224
tests/fm-grok-harness.test.sh 317
tests/fm-grok-stop-live-e2e.test.sh 281
tests/fm-guard-stale-banner.test.sh 505
tests/fm-harness-adapter-instructions-live-e2e.test.sh 293
tests/fm-harness-adapter-references.test.sh 166
tests/fm-harness-liveness-drift-live-e2e.test.sh 211
tests/fm-harness-shuvcode.test.sh 239
tests/fm-herdr-lab.test.sh 291
tests/fm-herdr-session-cleanup-e2e.test.sh 51
tests/fm-herdr-session-cleanup.test.sh 362
tests/fm-herdr-submit-confirm-live-e2e.test.sh 237
tests/fm-herdr-version-floor-live-e2e.test.sh 223
tests/fm-home-summary-refresh.test.sh 715
tests/fm-inactive-reconcile.test.sh 583
tests/fm-kimi-harness.test.sh 468
tests/fm-lint-workflows.test.sh 372
tests/fm-lint.test.sh 886
tests/fm-live-gate.test.sh 276
tests/fm-mail-check.test.sh 351
tests/fm-mail.test.sh 1057
tests/fm-muse-harness.test.sh 1714
tests/fm-muse-signals-live-e2e.test.sh 1559
tests/fm-nm-test-contract.test.sh 163
tests/fm-no-mistakes-required.test.sh 177
tests/fm-omp-harness.test.sh 2264
tests/fm-omp-primary-live-e2e.test.sh 309
tests/fm-on.test.sh 1358
tests/fm-opencode-primary-live-e2e.test.sh 321
tests/fm-opencode-v2-acceptance-lib.sh 335
tests/fm-opencode-v2-guard-acceptance.test.sh 469
tests/fm-opencode-v2-herdr-detach-live.test.sh 735
tests/fm-opencode-v2-herdr-transport-smoke-live.test.sh 161
tests/fm-opencode-v2-launch.test.sh 668
tests/fm-opencode-v2-lead.test.sh 242
tests/fm-opencode-v2-live-binary-lib.sh 43
tests/fm-opencode-v2-ownership-acceptance.test.sh 494
tests/fm-opencode-v2-plugin.test.sh 511
tests/fm-opencode-v2-shared-service-live.test.sh 1077
tests/fm-opencode-v2-succession-live.test.sh 945
tests/fm-opencode-v2-tui-acceptance.test.sh 1378
tests/fm-opencode-v2-wake-admission.test.sh 785
tests/fm-opencode-v2-worker-live-e2e.test.sh 930
tests/fm-opencode-v2-worker-restart-acceptance.test.sh 545
tests/fm-operational-input.test.sh 223
tests/fm-peek-remote.test.sh 206
tests/fm-pending-reply-10.test.sh 33414
tests/fm-pending-reply-2.test.sh 17156
tests/fm-pending-reply-3.test.sh 18005
tests/fm-pending-reply-4.test.sh 19394
tests/fm-pending-reply-5.test.sh 17181
tests/fm-pending-reply-6.test.sh 17242
tests/fm-pending-reply-7.test.sh 17698
tests/fm-pending-reply-8.test.sh 37569
tests/fm-pending-reply-9.test.sh 17512
tests/fm-pending-reply-fixture.sh 15848
tests/fm-pending-reply.test.sh 18214
tests/fm-persona-lib.test.sh 397
tests/fm-pi-branch-extension.test.sh 624
tests/fm-pi-branch-live-e2e.test.sh 246
tests/fm-pi-branch-responsiveness-live-e2e.test.sh 241
tests/fm-pi-codex-native.test.sh 184
tests/fm-pi-primary-live-e2e.test.sh 362
tests/fm-pi-primary-types.test.sh 19
tests/fm-pi-watch-extension.test.sh 810
tests/fm-pi-windows-shell-invocation.test.sh 180
tests/fm-pr-check-security.test.sh 1294
tests/fm-pr-merge.test.sh 1033
tests/fm-procevent-quota.test.sh 59
tests/fm-procevent-when.test.sh 375
tests/fm-procevent.test.sh 3958
tests/fm-project-origin.test.sh 227
tests/fm-public-followup.test.sh 6919
tests/fm-quota-array-dispatch-live-e2e.test.sh 191
tests/fm-quota-choose.test.sh 161
tests/fm-remote-backlog-handoff.test.sh 389
tests/fm-remote-doctor.test.sh 540
tests/fm-remote-entrypoint.test.sh 174
tests/fm-remote-herdr-guard.test.sh 356
tests/fm-remote-job-orphan-reap.test.sh 1232
tests/fm-remote-job.test.sh 2843
tests/fm-remote-reply.test.sh 20779
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 1052
tests/fm-remote-secondmate-parent-binding.test.sh 310
tests/fm-remote-secondmate-trace-context.test.sh 307
tests/fm-remote-transport-lanes.test.sh 1416
tests/fm-review-diff.test.sh 213
tests/fm-rovo-harness.test.sh 350
tests/fm-rovo-signals-live-e2e.test.sh 581
tests/fm-secondmate-harness.test.sh 1507
tests/fm-secondmate-lifecycle-e2e.test.sh 310
tests/fm-secondmate-liveness.test.sh 371
tests/fm-secondmate-reconcile.test.sh 748
tests/fm-secondmate-restart.test.sh 502
tests/fm-secondmate-safety.test.sh 1950
tests/fm-secondmate-sync.test.sh 1281
tests/fm-send-inbox-doorbell-live-e2e.test.sh 252
tests/fm-send-inbox.test.sh 322
tests/fm-send-popup-settle.test.sh 209
tests/fm-send-remote-delivery.test.sh 18190
tests/fm-send-resolve-key.test.sh 599
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 228
tests/fm-send-secondmate-marker.test.sh 294
tests/fm-send-settle.test.sh 217
tests/fm-send-strict.test.sh 278
tests/fm-session-lock-ancestry.test.sh 385
tests/fm-session-start.test.sh 1572
tests/fm-sessionstart-hook-live-e2e.test.sh 422
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh 276
tests/fm-sessionstart-nudge.test.sh 454
tests/fm-shared-captain-inheritance.test.sh 353
tests/fm-sharkctl-guard.test.sh 395
tests/fm-spawn-batch.test.sh 232
tests/fm-spawn-dispatch-profile.test.sh 1664
tests/fm-spawn-pool-base-freshen.test.sh 759
tests/fm-spawn-worktree-settle.test.sh 382
tests/fm-startup-memory-budget.test.sh 337
tests/fm-startup-network.test.sh 590
tests/fm-stat-shadowing.test.sh 28844
tests/fm-stow-cascade.test.sh 353
tests/fm-subagent-pretool-check.test.sh 324
tests/fm-supervision-events.test.sh 244
tests/fm-supervision-instructions.test.sh 582
tests/fm-tangle-guard.test.sh 352
tests/fm-task-delivery.test.sh 540
tests/fm-task-inbox.test.sh 692
tests/fm-teardown-endpoint-safety.test.sh 646
tests/fm-teardown.test.sh 2151
tests/fm-test-fixture-cleanup.test.sh 225
tests/fm-test-fixtures.test.sh 356
tests/fm-test-isolation-proof.test.sh 266
tests/fm-test-run.test.sh 992
tests/fm-tmux-agent-liveness.test.sh 1139
tests/fm-tmux-submit-busy.test.sh 336
tests/fm-tool-update-check.test.sh 670
tests/fm-trace-context-lib.test.sh 309
tests/fm-trace-context-spawn.test.sh 480
tests/fm-transition-lib.test.sh 220
tests/fm-turnend-guard.test.sh 1498
tests/fm-update.test.sh 348
tests/fm-vendor-auth-probe.test.sh 319
tests/fm-voice-relay.test.sh 744
tests/fm-wake-daemon-lifecycle-e2e.test.sh 308
tests/fm-wake-drain-open-decisions-cursor.test.sh 419
tests/fm-wake-drain-open-decisions.test.sh 325
tests/fm-wake-drain-outcome-backstop.test.sh 532
tests/fm-wake-drain-unread-status.test.sh 445
tests/fm-wake-queue.test.sh 1413
tests/fm-watch-arm.test.sh 706
tests/fm-watch-checkpoint.test.sh 212
tests/fm-watch-recovery-loop.test.sh 331
tests/fm-watch-triage.test.sh 3884
tests/fm-watcher-lock.test.sh 1070
tests/fm-x-mode.test.sh 2394
tests/herdr-client-pair-fixture.sh 9
tests/herdr-test-safety.sh 6
tests/lib.sh 137
tests/remote-herdr-fixture.sh 9
tests/secondmate-helpers.sh 187
tests/wake-helpers.sh 237
tests/zellij-test-safety.sh 12
EOF
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ -z "$CI_SHARD" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
if [ "$CHANGED_MODE" -eq 1 ] && [ "$FAST" -eq 0 ]; then
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  ANALYSIS_MODE=local
fi
# Two concurrent source-following processes exhaust a hosted runner. The
# explicit job selectors above still choose 1 or 2.
if [ "$JOBS_EXPLICIT" -eq 0 ] && [ "$FOLLOW_SOURCES" -eq 1 ]; then
  JOBS=1
fi
ROOT_COUNT=${#ROOTS[@]}

if [ -n "$CI_SHARD" ]; then
  # Hints are relative duration weights, not timeouts or coverage selectors.
  # Greedy longest-first assignment uses the lowest partition index on ties.
  ci_selected=()
  while IFS= read -r path; do
    ci_selected+=("$path")
  done < <(
    {
      fm_lint_ci_weight_hints | awk '{ printf "hint\t%s\t%s\n", $1, $2 }'
      LC_ALL=C wc -c "${ROOTS[@]}" | awk '
        $0 !~ /^[[:space:]]*[0-9]+ total$/ {
          path=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]/, "", path)
          printf "root\t%s\t%s\n", path, $1
        }
      '
    } | awk -F '\t' '
      $1 == "hint" { hint[$2]=$3; next }
      { weight=hint[$2]; if (!weight) { weight=int($3/10); if (weight<1000) weight=1000 }
        printf "%d\t%s\n", weight, $2 }
    ' | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | awk -F '\t' \
      -v count="$CI_SHARD_COUNT" -v selected="$CI_SHARD_INDEX" '
        BEGIN { for (i=1; i<=count; i++) load[i]=0 }
        { best=1; for (i=2; i<=count; i++) if (load[i]<load[best]) best=i
          load[best]+=$1; if (best==selected) print $2 }
      ' | LC_ALL=C sort
  )
  ROOTS=("${ci_selected[@]}")
  ROOT_COUNT=${#ROOTS[@]}
  [ "$ROOT_COUNT" -gt 0 ] || {
    printf 'fm-lint.sh: CI partition %s selected no canonical roots.\n' "$CI_SHARD" >&2
    exit 2
  }
fi

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
elif [ "$FOLLOW_SOURCES" -eq 0 ]; then
  printf 'fm-lint.sh: local changed-file mode; ShellCheck source following disabled\n' >&2
elif [ "$ONE_FILE" -eq 1 ]; then
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled, one root per process\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

index=1
: > "$WEIGHTS"
for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  if [ -f "$path" ]; then
    weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  else
    weight=1
  fi
  case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
  printf '%s\t%s\t%s\n' "$weight" "$index" "$path" >> "$WEIGHTS"
  index=$((index + 1))
done

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_INTERNAL_ONE_FILE="$ONE_FILE" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_INTERNAL_ONE_FILE="$ONE_FILE" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
      FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
      FM_LINT_INTERNAL_ONE_FILE="$ONE_FILE" \
      FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  if [ "$FOLLOW_SOURCES" -eq 1 ]; then
    source_followed=$((source_directives - source_boundaries))
  else
    source_followed=0
  fi
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'ci_partition\t%s\n' "${CI_SHARD:-none}"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
