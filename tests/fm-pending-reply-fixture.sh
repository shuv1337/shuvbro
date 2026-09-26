#!/usr/bin/env bash
# Shared prelude for the pending-reply behavior tests.
# Those tests are split across several scripts so ShellCheck's source-aware
# dataflow of one script stays inside the 8g self-hosted container.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
# shellcheck disable=SC2034 # Read by the pending-reply scripts that source this prelude.
REPORT="$ROOT/bin/fm-secondmate-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-pending-reply)

export FM_PENDING_REPLY_GRACE_SECS=0
export FM_SEND_SETTLE=0

# --- fixtures ---------------------------------------------------------------

make_stubs() {  # <dir> -> fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_parent() {  # <name> -> home
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Seed a local secondmate home bound to <parent> with identity <id>.
bind_local_mate() {  # <parent-home> <id> -> mate-home
  local parent=$1 id=$2 mate
  mate="$TMP_ROOT/${id}-home-$RANDOM"
  mkdir -p "$mate/state"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  cat > "$mate/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$parent
EOF
  printf '%s\n' "$mate"
}

run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_PENDING_REPLY_GRACE_SECS=0 \
    "$SEND" "$@" 2>/dev/null
}

phase_of() {  # <state> <corr>
  fm_pending_reply_get "$(fm_pending_reply_path "$1" "$2")" phase
}

# A local steer now rides the durable steering inbox rather than the typed
# channel, so marker/corr assertions read the latest enqueued record through
# the production owner (bin/fm-task-inbox-lib.sh).
latest_record_body() {  # <home> <task>
  local rec
  rec=$(find "$1/state/$2.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | sort | tail -1)
  [ -n "$rec" ] || return 1
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec"
}

