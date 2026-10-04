#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Shuvcode (OpenCode V2 fork) is likewise delegated rather than added to the
# tables: its binary name `shuvcode` is specific, but its launcher is a node
# script and its session service parents tool subprocesses, so the whole
# structural rule - exact name, node interpreter, whole path component - lives
# in one owner (adapter id opencode-v2). It is sourced defensively so a stale
# fixture tree that copied this lib before its owner existed still fails closed
# with no shuvcode evidence instead of printing an error on every ancestry hop.
# shellcheck source=bin/fm-shuvcode-lib.sh
if [ -r "$(dirname -- "${BASH_SOURCE[0]}")/fm-shuvcode-lib.sh" ]; then
  . "$(dirname -- "${BASH_SOURCE[0]}")/fm-shuvcode-lib.sh"
else
  fm_shuvcode_process_matches() { return 1; }
fi

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  # Shuvcode: the same delegation, from the exact `shuvcode` name or a node
  # interpreter running the shuvcode launcher. Without this a shuvcode primary
  # can never locate its own harness in the ancestry either, so every session
  # start refuses the fleet lock as read-only - the failure this owner exists
  # to fix. It matches only shuvcode evidence, never V1 opencode.
  fm_shuvcode_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    # A shared execution service is an ancestry barrier, not just an ignored
    # harness. Never climb through it and adopt the TUI/job that started it.
    case " $args " in
      *' --service '*)
        if fm_shuvcode_process_matches "$comm" "${args/--service/}"; then break; fi
        ;;
    esac
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  # A native V2 model shell belongs to the shared execution service, not the
  # owning TUI's ancestry. The supplemental owner is exact-session scoped.
  if [ -n "${OPENCODE_SESSION_ID:-}" ]; then
    local v2_owner v2_lib v2_probe
    v2_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-opencode-v2-owner.mjs"
    if v2_owner=$(node "$v2_lib" helper "${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$(dirname "$v2_lib")")}}/state}" acquire 2>&1); then
      printf '%s\n' "$v2_owner"
      return 0
    fi
    if [ -f "$v2_lib" ]; then
      v2_probe=0
      node "$v2_lib" probe "$OPENCODE_SESSION_ID" >/dev/null 2>&1 || v2_probe=$?
      if [ "$v2_probe" -ne 3 ]; then printf '%s\n' "$v2_owner" >&2; return 1; fi
    fi
  fi
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  if [ -n "${OPENCODE_SESSION_ID:-}" ]; then
    local v2_lib v2_probe v2_owner
    v2_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-opencode-v2-owner.mjs"
    if v2_owner=$(node "$v2_lib" helper "$1" 2>&1); then return 0; fi
    if [ -f "$v2_lib" ]; then
      v2_probe=0
      node "$v2_lib" probe "$OPENCODE_SESSION_ID" >/dev/null 2>&1 || v2_probe=$?
      if [ "$v2_probe" -ne 3 ]; then printf '%s\n' "$v2_owner" >&2; return 1; fi
    fi
  fi
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# True when $1 is an executable ELF whose basename is shuvcode.
# bin/fm-opencode-v2-primary.sh accepts only that file. A node launcher or npm
# wrapper forks a different PID and cannot own the lead.
fm_path_is_shuvcode_elf() {  # <path>
  local path=$1 magic
  [ -n "$path" ] && [ -f "$path" ] && [ -x "$path" ] || return 1
  [ "$(basename -- "$path")" = shuvcode ] || return 1
  magic=$(head -c 4 -- "$path" 2>/dev/null) || return 1
  [ "$magic" = $'\177ELF' ]
}

# Linux package names in the order shuvcode's npm launcher selects them:
# musl and non-AVX2 hosts try their variant first, then the generic host
# package. Other platforms are absent; activation is Linux-only.
fm_opencode_v2_platform_package_names() {
  local arch='' musl=0 baseline=0 base
  case "$(uname -s)" in
    Linux) ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7*|armv6*) arch=arm ;;
    *) return 1 ;;
  esac
  if [ -e /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; then
    musl=1
  fi
  if [ "$arch" = x64 ] && [ -r /proc/cpuinfo ] \
    && ! grep -E -q '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo; then
    baseline=1
  fi
  base="shuvcode-linux-${arch}"
  if [ "$musl" -eq 1 ]; then
    if [ "$arch" = x64 ] && [ "$baseline" -eq 1 ]; then
      printf '%s\n' "${base}-baseline-musl" "${base}-musl" "${base}-baseline" "$base"
    elif [ "$arch" = x64 ]; then
      printf '%s\n' "${base}-musl" "${base}-baseline-musl" "$base" "${base}-baseline"
    else
      printf '%s\n' "${base}-musl" "$base"
    fi
  elif [ "$arch" = x64 ] && [ "$baseline" -eq 1 ]; then
    printf '%s\n' "${base}-baseline" "$base" "${base}-baseline-musl" "${base}-musl"
  elif [ "$arch" = x64 ]; then
    printf '%s\n' "$base" "${base}-baseline" "${base}-musl" "${base}-baseline-musl"
  else
    printf '%s\n' "$base" "${base}-musl"
  fi
}

# The installed native ELF, never the npm wrapper.
# The running `shuvcode serve --service` process is authoritative when its
# executable is that ELF. Otherwise follow the launcher the same way the
# live suites do: the platform package nested beside it, then the launcher
# itself when it is already the ELF.
fm_opencode_v2_native_binary() {  # [service-pid]
  local pid=${1:-} exe launcher dir name candidate
  if [ -n "$pid" ]; then
    exe=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
    if fm_path_is_shuvcode_elf "$exe"; then
      printf '%s\n' "$exe"
      return 0
    fi
  fi
  launcher=$(command -v shuvcode 2>/dev/null) || return 1
  launcher=$(readlink -f -- "$launcher" 2>/dev/null) || return 1
  if fm_path_is_shuvcode_elf "$launcher"; then
    printf '%s\n' "$launcher"
    return 0
  fi
  dir=$(dirname -- "$launcher")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    for candidate in \
      "$dir/../node_modules/$name/bin/shuvcode" \
      "$dir/../../node_modules/$name/bin/shuvcode" \
      "$dir/../../$name/bin/shuvcode"
    do
      [ -e "$candidate" ] || continue
      candidate=$(readlink -f -- "$candidate" 2>/dev/null) || continue
      if fm_path_is_shuvcode_elf "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done < <(fm_opencode_v2_platform_package_names)
  return 1
}

# Closest ancestor that is the shared shuvcode service. That process is an
# ancestry barrier, so it can never be the session-lock pid.
fm_opencode_v2_service_ancestor_pid() {
  local pid=$$ comm args _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    case " $args " in
      *' --service '*)
        if fm_shuvcode_runtime_matches "$comm" "$args"; then
          printf '%s\n' "$pid"
          return 0
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  return 1
}

# Report why fm_harness_ancestry_pid failed.
# An OpenCode V2 model shell with no owner registration (probe exit 3) sits
# under `shuvcode serve --service`, so the ancestry walk stops and the generic
# "cannot locate harness" line names the barrier instead of the missing
# activation. Only that cause is replaced. Every other failure keeps the
# ancestry error, including a set OPENCODE_SESSION_ID whose probe did not
# exit 3 or whose tree has no shared-service barrier.
fm_lock_missing_harness_error() {
  local session=${OPENCODE_SESSION_ID:-} bin_dir v2_lib probe=0 service_pid native primary
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -n "$session" ] && [ -f "$bin_dir/fm-opencode-v2-owner.mjs" ]; then
    v2_lib=$bin_dir/fm-opencode-v2-owner.mjs
    node "$v2_lib" probe "$session" >/dev/null 2>&1 || probe=$?
    if [ "$probe" -eq 3 ] && service_pid=$(fm_opencode_v2_service_ancestor_pid); then
      primary=$bin_dir/fm-opencode-v2-primary.sh
      if native=$(fm_opencode_v2_native_binary "$service_pid"); then
        printf 'error: OpenCode V2 lead not activated; run %q --session %q --native-binary %q\n' \
          "$primary" "$session" "$native" >&2
      else
        printf 'error: OpenCode V2 lead not activated; the native shuvcode executable could not be resolved. Run %q --session %q --native-binary with the installed Linux ELF, not the npm wrapper.\n' \
          "$primary" "$session" >&2
      fi
      return 0
    fi
  fi
  echo "error: cannot locate harness process in ancestry" >&2
}
