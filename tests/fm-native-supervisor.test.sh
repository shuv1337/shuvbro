#!/usr/bin/env bash
# Hermetic public native entrypoint behavior; no legacy home, live session or credentials.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
node --test "$SELF_DIR/fm-native-supervisor.test.mjs"
