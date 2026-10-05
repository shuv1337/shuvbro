#!/usr/bin/env bash
# Resolve a runnable installed shuvcode for the isolated live guards.
# An explicit FM_OPENCODE_V2_BIN must work. Otherwise use dispatch's host
# preference order and skip candidates that fail --version. Only read-only
# version calls are made before XDG isolation.
# shellcheck source=bin/fm-shuvcode-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-shuvcode-lib.sh"

v2_resolve_live_binary() {
  local launcher dir candidate name root names
  if [ -n "${FM_OPENCODE_V2_BIN:-}" ]; then
    if "$FM_OPENCODE_V2_BIN" --version >/dev/null 2>&1; then
      printf '%s' "$FM_OPENCODE_V2_BIN"
      return
    fi
    printf 'cannot run explicit shuvcode binary: %s\n' "$FM_OPENCODE_V2_BIN" >&2
    return 1
  fi
  launcher=$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$(command -v shuvcode)") || return 1
  if fm_shuvcode_is_native_executable "$launcher" && "$launcher" --version >/dev/null 2>&1; then
    printf '%s' "$launcher"
    return
  fi
  dir=$(dirname "$launcher")
  names=$(fm_shuvcode_platform_package_names) || names=''
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    for root in "$dir/../node_modules" "$dir/../.."; do
      candidate="$root/$name/bin/shuvcode"
      if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
        node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$candidate"
        return
      fi
    done
  done <<< "$names"
  if "$launcher" --version >/dev/null 2>&1; then
    printf '%s' "$launcher"
    return
  fi
  printf 'no runnable installed shuvcode binary found\n' >&2
  return 1
}
