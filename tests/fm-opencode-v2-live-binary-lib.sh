#!/usr/bin/env bash
# Resolve a runnable installed shuvcode for the isolated live guards.
# An explicit FM_OPENCODE_V2_BIN must work; otherwise probe platform packages
# with --version rather than trusting glob order (musl may be installed on a
# glibc host). Only read-only version calls are made before XDG isolation.
v2_resolve_live_binary() {
  local launcher dir candidate
  if [ -n "${FM_OPENCODE_V2_BIN:-}" ]; then
    if "$FM_OPENCODE_V2_BIN" --version >/dev/null 2>&1; then
      printf '%s' "$FM_OPENCODE_V2_BIN"
      return
    fi
    printf 'cannot run explicit shuvcode binary: %s\n' "$FM_OPENCODE_V2_BIN" >&2
    return 1
  fi
  launcher=$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$(command -v shuvcode)") || return 1
  dir=$(dirname "$launcher")
  for candidate in "$dir"/../node_modules/shuvcode-*/bin/shuvcode "$dir"/../../shuvcode-*/bin/shuvcode; do
    if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$candidate"
      return
    fi
  done
  if "$launcher" --version >/dev/null 2>&1; then
    printf '%s' "$launcher"
    return
  fi
  printf 'no runnable installed shuvcode binary found\n' >&2
  return 1
}
