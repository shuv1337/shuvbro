#!/usr/bin/env bash
# Default OpenCode V2 lead launcher: resolve the installed native shuvcode
# executable and the exact lead session, then exec the explicit activation
# bin/fm-opencode-v2-primary.sh, which owns every ownership and launch rule.
# A plain `shuvcode` launch is never activated, so its session start stays
# read-only; this is the supported way to open or resume a lead instead.
#
# Usage: fm-opencode-v2-lead.sh [--continue | --new | --session ID] [--native-binary PATH]
#   --continue (default)  resume the newest top-level session whose directory is
#                         this code root, creating one when none exists. The
#                         session list is project-scoped and includes sibling
#                         copies and worktrees, so only an exact directory
#                         match counts.
#   --new                 create a fresh session at this code root.
#   --session ID          resume exactly that session.
#   --native-binary PATH  skip resolution; otherwise fm_shuvcode_native_binary
#                         (bin/fm-shuvcode-lib.sh) resolves it and honors
#                         FM_OPENCODE_V2_BIN.
# Session discovery and creation use `shuvcode` on PATH against the default
# shared service. FM_HOME and the other frozen overrides pass through to the
# activation unchanged. Linux only, like the activation it wraps.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-shuvcode-lib.sh
. "$SCRIPT_DIR/fm-shuvcode-lib.sh"

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
die() { echo "error: $*" >&2; exit 2; }

mode=continue session='' binary=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --continue) mode=continue; shift ;;
    --new) mode=new; shift ;;
    --session)
      [ "$#" -ge 2 ] || die '--session needs an ID'
      mode=session session=$2; shift 2 ;;
    --native-binary)
      [ "$#" -ge 2 ] || die '--native-binary needs a PATH'
      binary=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

if [ -z "$binary" ]; then
  binary=$(fm_shuvcode_native_binary) \
    || die 'cannot resolve the installed native shuvcode executable; pass --native-binary PATH or set FM_OPENCODE_V2_BIN'
fi

root=$(realpath "${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}")
cd "$root"

create_session() {
  local created
  created=$(shuvcode api session.create --data "$(jq -cn --arg d "$root" '{location: {directory: $d}}')") \
    || die "cannot create a session at $root"
  jq -er '.data.id' <<< "$created" 2>/dev/null || die "session create returned no session id: $created"
}

case "$mode" in
  continue)
    sessions=$(shuvcode session list --format json --max-count 100) || die "cannot list sessions for $root"
    session=$(jq -r --arg d "$root" '[.[] | select(.directory == $d)] | max_by(.updated) | .id // empty' <<< "$sessions") \
      || die "cannot read the session list for $root"
    if [ -z "$session" ]; then
      session=$(create_session)
      echo "no lead session found at $root; created $session" >&2
    else
      echo "resuming lead session $session" >&2
    fi
    ;;
  new)
    session=$(create_session)
    echo "created lead session $session" >&2
    ;;
esac

exec "$SCRIPT_DIR/fm-opencode-v2-primary.sh" --session "$session" --native-binary "$binary"
