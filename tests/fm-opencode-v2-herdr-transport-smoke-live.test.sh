#!/usr/bin/env bash
# Herdr transport smoke for the OpenCode V2 owner leg: runs
# tests/fm-opencode-v2-herdr-detach-live.test.sh with its built-in stand-in
# owner and stand-in execution process. It proves only the guarded lab,
# real-client attach, detach and reattach plumbing through bin/fm-herdr-lab.sh;
# it is NOT product evidence (no shuvcode, no adapter) and is refused under
# FM_V2_ACCEPT_STRICT=1. Run with FM_OPENCODE_V2_HERDR_SMOKE_LIVE=1.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_V2_HERDR_SMOKE_LIVE herdr termctrl jq
unset FM_V2_HERDR_OWNER_CMD FM_V2_HERDR_OWNER_PID_CMD FM_V2_HERDR_SENTINEL_CMD FM_V2_HERDR_RETIRED_CMD FM_V2_HERDR_EXEC_CMD
FM_V2_HERDR_TRANSPORT_SMOKE=1 exec bash "$ROOT/tests/fm-opencode-v2-herdr-detach-live.test.sh"
