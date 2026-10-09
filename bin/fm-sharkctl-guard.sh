#!/usr/bin/env bash
# fm-sharkctl-guard.sh - PATH shim that stops a task worker from notifying the captain.
#
# Ship and scout panes prepend bin/worker-guards (a symlink to this file, named
# sharkctl) to PATH on the same pre-launch channel as FM_TASK_ID. fm-spawn.sh
# owns that injection. While FM_TASK_ID is set, the first positional verb
# `notify` or `ask` refuses, including `sharkctl notify ask`, as does any `board`
# argument. Every other verb,
# and every invocation with FM_TASK_ID unset, execs the next sharkctl on PATH.
# The lead and a secondmate pane are unmarked, so they are not redirected here.
# An absolute path to some other sharkctl bypasses a PATH shim; the worker
# brief is what forbids that, and this file owns only the PATH refusal.
set -eu

refuse() {
  printf '%s\n' "error: task worker FM_TASK_ID=$FM_TASK_ID must not contact the captain with sharkctl $1; send the question to firstmate as a keyed status line" >&2
  exit 1
}

if [ -n "${FM_TASK_ID:-}" ]; then
  verb=
  for arg in "$@"; do
    case "$arg" in
      --) break ;;
      -*) continue ;;
      *) verb=$arg; break ;;
    esac
  done
  for arg in "$@"; do
    [ "$arg" != board ] || refuse board
  done
  case "$verb" in
    notify|ask) refuse "$verb" ;;
  esac
fi

# Bash's file-identity test follows symlinks on Linux and macOS, so every
# alias of this guard is skipped before delegation to the real sharkctl.
same_file() {
  [ "$1" -ef "$2" ]
}

# A separate copy of this guard later on PATH is not the same file. Delegation
# hands it FM_SHARKCTL_GUARD_REST, the PATH entries after the one it was found
# in, so each hop searches strictly further along PATH and the chain ends.
next_sharkctl() {
  local path=${PATH-} dir candidate
  if [ -n "${FM_SHARKCTL_GUARD_REST+set}" ]; then
    path=$FM_SHARKCTL_GUARD_REST
  fi
  while [ -n "$path" ]; do
    dir=${path%%:*}
    case "$path" in
      *:*) path=${path#*:} ;;
      *) path= ;;
    esac
    [ -n "$dir" ] || dir=.
    candidate=$dir/sharkctl
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    same_file "$0" "$candidate" && continue
    printf '%s\n%s\n' "$path" "$candidate"
    return 0
  done
  return 1
}

if ! found=$(next_sharkctl); then
  printf '%s\n' "error: sharkctl: command not found" >&2
  exit 127
fi
export FM_SHARKCTL_GUARD_REST="${found%%$'\n'*}"
exec "${found#*$'\n'}" "$@"
