#!/usr/bin/env bash
# Shuvcode (OpenCode V2 fork) process identity.
# Sourced by bin/fm-harness.sh, bin/fm-session-lock-lib.sh, and
# bin/fm-opencode-v2-lead.sh.
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
  local args=$1 token
  [ -n "$args" ] || return 1
  # Only the interpreter's script token can identify its launcher. A fixture
  # like node /tmp/shuvcode/lab/run.mjs is NOT the native npm launcher merely
  # because an ancestor directory happens to be called shuvcode.
  local -a tokens
  read -r -a tokens <<< "$args"
  for token in "${tokens[@]:1}"; do
    case "$token" in
      -*) continue ;;
      */shuvcode|shuvcode) return 0 ;;
      */shuvcode/bin/shuvcode.js) return 0 ;;
      *) return 1 ;;
    esac
  done
  return 1
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
    *' --service '*) return 1 ;;
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
       case "$argv0" in */shuvcode|*/shuvcode/bin/shuvcode.js) return 0 ;; esac
      return 1
      ;;
  esac
  # A renamed or path-named executable still identifies through its own path,
  # the same widening fm_harness_path_name applies to the table harnesses.
  fm_shuvcode_path_has_component "$comm" && return 0
  return 1
}

# Runtime detection is not session-lock authority. A shared service correctly
# identifies the tool runtime even though it is excluded from lock ancestry.
fm_shuvcode_runtime_matches() {
  fm_shuvcode_process_matches "$1" "${2/--service/}" "${3:-}"
}

# True when path $1 is an executable Linux ELF file - the only shape explicit
# V2 lead activation can exec while keeping its own PID.
fm_shuvcode_is_native_executable() {  # <path>
  [ -f "$1" ] && [ -x "$1" ] && [ "$(head -c 4 -- "$1" 2>/dev/null)" = $'\177ELF' ]
}

# Print the installed native shuvcode executable for explicit V2 lead
# activation, or return 1. The npm `shuvcode` command is a node launcher that
# forks the platform binary as a child, so activation must exec that binary
# directly. Resolution inspects paths and never executes a shuvcode binary:
#   1. FM_OPENCODE_V2_BIN, when set, is the only candidate.
#   2. `shuvcode` on PATH, when it already resolves to a native executable.
#   3. The launcher's platform packages, nested (<pkg>/node_modules) or hoisted
#      (sibling of <pkg>), in the launcher's own preference order: baseline
#      first on x64 without AVX2, musl first on a musl host.
fm_shuvcode_native_binary() {
  local launcher dir arch base root name
  local -a names
  if [ -n "${FM_OPENCODE_V2_BIN:-}" ]; then
    fm_shuvcode_is_native_executable "$FM_OPENCODE_V2_BIN" || return 1
    readlink -f -- "$FM_OPENCODE_V2_BIN"
    return
  fi
  launcher=$(command -v shuvcode 2>/dev/null) || return 1
  launcher=$(readlink -f -- "$launcher") || return 1
  if fm_shuvcode_is_native_executable "$launcher"; then
    printf '%s\n' "$launcher"
    return 0
  fi
  [ "$(uname -s)" = Linux ] || return 1
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  base=shuvcode-linux-$arch
  if [ "$arch" = x64 ] && ! grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
    names=("$base-baseline" "$base")
  else
    names=("$base" "$base-baseline")
  fi
  # The launcher's own musl test: the C library ldd reports, not whether a
  # musl loader merely happens to be installed beside glibc.
  if ldd --version 2>&1 | grep -qi musl; then
    names=("${names[@]/%/-musl}" "${names[@]}")
  else
    names=("${names[@]}" "${names[@]/%/-musl}")
  fi
  dir=$(dirname -- "$launcher")
  for name in "${names[@]}"; do
    for root in "$dir/../node_modules" "$dir/../.."; do
      if fm_shuvcode_is_native_executable "$root/$name/bin/shuvcode"; then
        readlink -f -- "$root/$name/bin/shuvcode"
        return
      fi
    done
  done
  return 1
}
