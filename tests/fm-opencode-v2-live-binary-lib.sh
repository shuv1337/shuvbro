#!/usr/bin/env bash
# Resolve the installed shuvcode for the isolated live guards exactly as
# dispatch does (fm_shuvcode_native_binary), then require that one binary to
# run --version. A dispatch choice that cannot run fails the guard instead of
# being replaced by another candidate. Only a read-only version call is made
# before XDG isolation.
# shellcheck source=bin/fm-shuvcode-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-shuvcode-lib.sh"

v2_resolve_live_binary() {
  local binary
  if ! binary=$(fm_shuvcode_native_binary); then
    printf 'dispatch resolved no native shuvcode binary\n' >&2
    return 1
  fi
  if ! "$binary" --version >/dev/null 2>&1; then
    printf 'cannot run dispatch-selected shuvcode binary: %s\n' "$binary" >&2
    return 1
  fi
  printf '%s' "$binary"
}
