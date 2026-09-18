#!/usr/bin/env bash
# Shuvcode (OpenCode V2 fork) process identity.
# Sourced by bin/fm-harness.sh and bin/fm-session-lock-lib.sh.
# This file is sourced by scripts and has no side effects on source.
#
# Why one owner: shuvcode is a V2 OpenCode fork distributed under its own
# names - a node-script launcher and a compiled `shuvcode` binary - and its
# session service parents firstmate tool subprocesses. Three callers must agree
# on the same narrowed rule: the session-lock ancestry walk and liveness probe
# (which pid may hold state/.lock), harness detection (which adapter id a
# shuvcode tree prints), and every caller that must not read shuvcode as V1
# opencode. A sloppy *opencode* glob would silently claim the upstream
# `opencode2` beta as V1 opencode, and a bare-name match could claim an
# unrelated command that merely contains shuvcode somewhere, so one owner keeps
# the structural rule identical everywhere.
#
# Process detection uses structural signals only - command name, arguments,
# argv[0] - never an executed probe: running a stranger's binary during an
# ancestry walk or a liveness poll is exactly the hazard this file exists to
# close.

# True when path $1 has a whole path component named `shuvcode`, e.g.
# /home/shuv/.local/bin/shuvcode or .../node_modules/shuvcode/.... A component
# merely prefixed with shuvcode (shuvcode-helper, not-shuvcode) is never
# enough, so an unrelated user or tool directory cannot claim the identity.
fm_shuvcode_path_has_component() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "/$path/" in
    */shuvcode/*) return 0 ;;
  esac
  return 1
}

# True when argument string $1 references shuvcode: a whole token or whole
# path component named shuvcode (trailing basename or directory component).
# shuvcode-helper, not-shuvcode, and a mention embedded in another word never
# match.
fm_shuvcode_args_are_shuvcode() {  # <args>
  local args=$1
  [ -n "$args" ] || return 1
  printf '%s' "$args" | grep -qE '(^|[[:space:]/])shuvcode([[:space:]/]|$)' || return 1
}

# True when the process described by command name $1 and argument string $2
# (plus structured argv0 $3 when available) is shuvcode. The single owner of
# shuvcode process identity for the ancestry walk (bin/fm-session-lock-lib.sh),
# harness detection (bin/fm-harness.sh), and liveness probes.
#
# Accepted: an exact `shuvcode` command name - the compiled binary reports comm
# `shuvcode` (verified, shuvcode v2.0.0-alpha-20 on Linux), and macOS reports
# the invoked path whose basename is shuvcode; and a node-family interpreter
# (node, node-MainThread, MainThread, nodejs) whose arguments or argv[0]
# reference the shuvcode launcher or an install path.
#
# Rejected: a bare or renamed process with no shuvcode evidence; anything whose
# name merely starts with shuvcode; any V1 or beta opencode name (opencode,
# opencode2) - those never carry shuvcode identity.
fm_shuvcode_process_matches() {  # <comm> <args> [argv0]
  local comm=$1 args=${2:-} argv0=${3:-} base
  [ -n "$comm" ] || [ -n "$argv0" ] || return 1
  # The shared background service outlives every individual session, so it can
  # never identify a session or own one home's session lock. A standalone
  # session's child server is distinguishable as `serve --stdio` and remains
  # eligible, as do its launcher and TUI processes.
  case " $args " in
    *' serve --service '*) return 1 ;;
  esac
  argv0=${argv0:-$comm}
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    shuvcode) return 0 ;;
    # A bare interpreter must show shuvcode evidence in its arguments or
    # argv[0]: without that bound the args of EVERY node process would be
    # searchable. MainThread alone carries no identity.
    node|node-*|node[0-9]*|nodejs|MainThread)
      fm_shuvcode_args_are_shuvcode "$args" && return 0
      fm_shuvcode_path_has_component "$argv0" && return 0
      return 1
      ;;
  esac
  # A renamed or path-named executable still identifies through its own path,
  # the same widening fm_harness_path_name applies to the table harnesses.
  fm_shuvcode_path_has_component "$comm" && return 0
  return 1
}
