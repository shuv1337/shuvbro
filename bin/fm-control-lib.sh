#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and the one bridge from those tables to opencode-v2's native session owner
# (fm_control_v2_*, which delegate to bin/fm-opencode-v2-session.mjs). Sourcing
# it has no side effects, and the tables run no backend command and read no
# state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. opencode-v2 is the one adapter whose interrupt is not a
#      key at all: its execution lives on the shared service, so its
#      acknowledgement source is the exact native session and its key tables
#      are deliberately empty. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, omp, and kimi have no verified pane-resume contract
# at all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction. opencode-v2's relaunch additionally resumes its exactly recorded
# native session (bin/fm-opencode-v2-launch.sh --resume), but it still admits
# the re-rendered brief, so the instructions on disk stay authoritative.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# Native shared execution outlives its pane. Query/interrupt the recorded session
# before any pane lifecycle action; callers must stop on an unproved outcome.
fm_control_v2_interrupt() {  # <state> <id> <worktree>
  node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-opencode-v2-session.mjs" interrupt "$1/$2.opencode-v2-session.json" "$3"
}

# The native half of opencode-v2's agent-free proof: whether the exactly
# recorded worker session has active execution on the shared service. Prints
# exactly one of:
#   idle        no active execution (or no recorded session and no busy claim)
#   executing   the recorded session is executing; a dead pane does not stop it
#   unproven    a successor service or absent binding cannot prove settlement
#   unreadable  the session owner refused or failed (its reason goes to stderr)
# A merely existing idle session is `idle`; only `idle` licenses calling the
# task agent-free. bin/fm-opencode-v2-session.mjs owns the proof itself.
fm_control_v2_execution() {  # <state> <id> <worktree>
  local out rc=0
  out=$(node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-opencode-v2-session.mjs" status "$1/$2.opencode-v2-session.json" "$3" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    printf 'unreadable'
    return 0
  fi
  printf '%s\n' "$out" | tail -n 1 | jq -r '
    if (type == "object") and has("executing") then
      if .executing == false then "idle"
      elif .executing == true then "executing"
      elif .executing == null then "unproven"
      else "unreadable" end
    else "unreadable" end' 2>/dev/null || printf 'unreadable'
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|opencode-v2|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp) return 0 ;;
  esac
  return 1
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands,
# `opencode-v2` is exact because the `opencode*` prefix would hand the shuvcode
# fork V1's key-based mechanics, and an unrecognized value returns nonzero
# rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    opencode-v2) printf 'opencode-v2' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    rovo*) printf 'rovo' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse, gemini, and rovo are
# crewmate/scout adapters only: none has a primary supervision protocol,
# and bin/fm-spawn.sh refuses a --secondmate launch on any of them. opencode-v2
# has a primary protocol, but its secondmate role is not qualified and
# bin/fm-spawn.sh refuses that launch too. The control plane asks this BEFORE
# it stops anything, so an incompatible relaunch target is refused while the
# current agent is still running rather than after it has been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini|rovo|opencode-v2) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
# rovo cancels on a single Escape too, printing "Agent cancelled" (verified,
# 202609.1.2). omp (Oh My Pi) shares Pi's single Escape, empty composer
# afterwards, and /quit exit (verified omp 18.1.2 in a PTY, re-verified 18.1.11
# through Herdr). opencode-v2 prints nothing: a pane key cannot reach execution
# that runs on the shared service, so its interrupt is the exact native session
# cancellation named by fm_control_interrupt_ack_source.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    opencode-v2) ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified key adapter interrupts on a single press, and
# opencode-v2 sends no key at all.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo) printf '1' ;;
    opencode-v2) printf '0' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|opencode-v2|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo) ;;
    *) return 1 ;;
  esac
}

# The adapter-owned acknowledgement an interrupt is confirmed from, or `none`.
# `native-session` also names the interrupt MECHANISM: the control plane
# cancels the exactly recorded opencode-v2 session through
# fm_control_v2_interrupt and confirms only that owner's settled result.
fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    opencode-v2) printf 'native-session' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    # rovo's TUI prints "Agent cancelled" on Escape, but for parity with
    # claude/cursor this stays 'none': the ack is a rendered string, not a
    # recorded state source, and rovo has no busy wiring to confirm against.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer. shuvcode's TUI binds
# /exit (aliases /quit and /q) to app.exit; exiting the TUI leaves its native
# session on the shared service, which fm-control proves idle separately.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|opencode-v2|grok|kimi|cursor|muse|rovo) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The named key sent after the exit command is typed and before each submit
# Enter, or nothing when the adapter needs none. Codex opens a slash popup on
# an exact `/quit` draft and that popup consumes Enter, leaving the draft and
# the `/quit  exit Codex` row in place. Escape dismisses the popup and leaves
# the draft unchanged, so the following Enter runs the bare command. Checked
# against the Codex TUI composer (openai/codex slash popup handling, 2026-10-04).
# A harness with no verified mechanics returns nonzero, matching the tables
# above. fm-control omits the key when the backend cannot deliver it.
fm_control_exit_dismiss_key() {  # <harness>
  case "${1-}" in
    codex) printf 'Escape' ;;
    claude|opencode|opencode-v2|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo) ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    # The worker package's .fm-owned.json stays: it is the task's ownership
    # proof that lets the same task re-arm the package, and teardown retires
    # it. The session sidecar is not wiring either: it is the binding a
    # same-harness relaunch resumes, and the exit proof already showed it idle.
    opencode-v2)
      printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js"
      printf '%s\n' "$wt/.opencode/plugins/fm-worker-v2/server.js"
      printf '%s\n' "$wt/.opencode/plugins/fm-worker-v2/package.json"
      ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
