#!/usr/bin/env bash
# Behavior tests for the worker captain-contact guard.
#
# Ship and scout panes receive FM_TASK_ID and a PATH prepend of
# bin/worker-guards before launch. That directory's sharkctl name refuses
# notify and ask while FM_TASK_ID is set. These tests run the shim, then
# replay the exact exports a fake-tmux spawn sent into the pane, with a decoy
# sharkctl behind the guard and no system sharkctl on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
GUARD="$ROOT/bin/worker-guards/sharkctl"
GUARD_DIR="$ROOT/bin/worker-guards"
TMP_ROOT=$(fm_test_tmproot fm-sharkctl-guard)
DECOY_DIR="$TMP_ROOT/decoy"
DECOY_LOG="$TMP_ROOT/decoy.log"
mkdir -p "$DECOY_DIR"
cat > "$DECOY_DIR/sharkctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$DECOY_LOG"
exit 0
SH
chmod +x "$DECOY_DIR/sharkctl"
# The shim's shebang is /usr/bin/env bash, so the interpreter must remain
# reachable. Keep this behind the decoy and refuse if it contains a real
# sharkctl, so a delegation cannot notify the host.
SYSTEM_PATH=/usr/bin:/bin
for shark_dir in /usr/bin /bin; do
  [ ! -e "$shark_dir/sharkctl" ] || fail "refusing to run with a real sharkctl at $shark_dir/sharkctl"
done

reset_decoy() {
  : > "$DECOY_LOG"
}

decoy_was_called() {
  [ -s "$DECOY_LOG" ]
}

# Run the PATH shim with the decoy behind it and nothing else on PATH.
# A caller may prefix FM_TASK_ID=...; an unmarked call strips any ambient value.
run_guard() {
  if [ -n "${FM_TASK_ID:-}" ]; then
    env FM_TASK_ID="$FM_TASK_ID" PATH="$GUARD_DIR:$DECOY_DIR:$SYSTEM_PATH" DECOY_LOG="$DECOY_LOG" "$GUARD" "$@"
  else
    env -u FM_TASK_ID PATH="$GUARD_DIR:$DECOY_DIR:$SYSTEM_PATH" DECOY_LOG="$DECOY_LOG" "$GUARD" "$@"
  fi
}

test_notify_ask_refuses_without_calling_sharkctl() {
  local out rc
  reset_decoy
  out=$(FM_TASK_ID=pp-explainer-hd11 run_guard notify ask --wait 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "sharkctl notify ask must refuse for a task worker"
  assert_contains "$out" "must not contact the captain with sharkctl notify" \
    "refusal did not name the forbidden verb"
  assert_contains "$out" "FM_TASK_ID=pp-explainer-hd11" \
    "refusal did not name the worker"
  decoy_was_called && fail "sharkctl notify ask invoked the real command: $(cat "$DECOY_LOG")"
  pass "FM_TASK_ID set: sharkctl notify ask refuses and does not call sharkctl"
}

test_ask_refuses_and_other_verbs_delegate() {
  local out rc
  reset_decoy
  out=$(FM_TASK_ID=worker-z1 run_guard ask --wait 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "sharkctl ask must refuse for a task worker"
  decoy_was_called && fail "sharkctl ask invoked the real command"
  assert_contains "$out" "sharkctl ask" "ask refusal did not name the verb"

  reset_decoy
  out=$(FM_TASK_ID=worker-z1 run_guard status 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a non-notify sharkctl verb must reach the next sharkctl (got: $out)"
  decoy_was_called || fail "sharkctl status did not reach the next sharkctl"
  [ "$(cat "$DECOY_LOG")" = "status" ] || fail "delegated sharkctl saw unexpected args: $(cat "$DECOY_LOG")"

  reset_decoy
  out=$(FM_TASK_ID=worker-z1 run_guard --json notify ask 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a flag before notify must still refuse"
  decoy_was_called && fail "sharkctl --json notify invoked the real command"
  pass "FM_TASK_ID set: ask refuses, other verbs delegate, flags do not hide notify"
}

test_unmarked_shell_delegates_notify_ask() {
  local out rc
  reset_decoy
  out=$(run_guard notify ask --wait 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "without FM_TASK_ID, sharkctl notify ask must reach the next sharkctl (got: $out)"
  [ "$(cat "$DECOY_LOG")" = "notify ask --wait" ] \
    || fail "unmarked sharkctl did not forward notify ask --wait: $(cat "$DECOY_LOG")"
  pass "FM_TASK_ID unset: sharkctl notify ask reaches the next sharkctl"
}

test_two_guard_aliases_delegate_once() {
  local first="$TMP_ROOT/alias-first" second="$TMP_ROOT/alias-second" out rc
  mkdir -p "$first" "$second"
  ln -s "$ROOT/bin/fm-sharkctl-guard.sh" "$first/sharkctl"
  ln -s "$ROOT/bin/fm-sharkctl-guard.sh" "$second/sharkctl"

  reset_decoy
  out=$(fm_run_timed 5 env FM_TASK_ID=worker-alias \
    PATH="$first:$second:$DECOY_DIR:$SYSTEM_PATH" DECOY_LOG="$DECOY_LOG" \
    "$first/sharkctl" live update --id fixture 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "two guard aliases must delegate a worker's allowed verb (got: $out)"
  [ "$(cat "$DECOY_LOG")" = "live update --id fixture" ] \
    || fail "two aliases must forward the worker invocation exactly once: $(cat "$DECOY_LOG")"

  reset_decoy
  out=$(fm_run_timed 5 env -u FM_TASK_ID \
    PATH="$first:$second:$DECOY_DIR:$SYSTEM_PATH" DECOY_LOG="$DECOY_LOG" \
    "$second/sharkctl" notify ask --wait 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "two guard aliases must delegate an unmarked invocation (got: $out)"
  [ "$(cat "$DECOY_LOG")" = "notify ask --wait" ] \
    || fail "two aliases must forward the unmarked invocation exactly once: $(cat "$DECOY_LOG")"
  pass "two guard aliases skip each other and delegate allowed and unmarked invocations once"
}

# Fake tmux: answers the pane-path query and logs every send-keys payload in
# order, so the test can replay the worker environment spawn actually sent.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

write_ship_brief() {  # <file>
  cat > "$1" <<'EOF'
# Task
## Captain's intent
Exercise the worker captain-contact guard.

## Firstmate spec
Confirm the spawned pane refuses sharkctl notify ask.
Delivery contract: mode=no-mistakes
EOF
}

prepare_spawn() {  # <name> -> home|proj|wt|fakebin|log|id
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/user-home"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id=$name-z1
  mkdir -p "$home/data/$id"
  write_ship_brief "$home/data/$id/brief.md"
  rm -rf "/tmp/fm-$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_spawn() {  # <home> <wt> <fakebin> <log> <id> <proj> [spawn args...]
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  shift 6
  : > "$launchlog"
  env -u FM_TASK_ID \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "printf worker" "$@" 2>&1
}

# Apply the FM_TASK_ID and PATH exports spawn sent, then eval a command in that
# environment. The shell starts with only the decoy on PATH, so a delegation
# can reach the decoy and cannot reach a sharkctl installed on the host.
replay() {  # <log> <command>
  local log=$1 cmd=$2
  # shellcheck disable=SC2016  # $1, $2, and the export lines expand in the replay shell.
  env -u FM_TASK_ID PATH="$DECOY_DIR:$SYSTEM_PATH" DECOY_LOG="$DECOY_LOG" bash -c '
    set -u
    log=$1
    cmd=$2
    while IFS= read -r line; do
      case "$line" in
        "export FM_TASK_ID="*|"export PATH="*) eval "$line" ;;
      esac
    done < "$log"
    eval "$cmd"
  ' bash "$log" "$cmd"
}

assert_guard_precedes_launch() {  # <log> <id>
  local log=$1 id=$2 path_line task_line launch_line
  task_line=$(grep -n "^export FM_TASK_ID=$id$" "$log" | tail -1 | cut -d: -f1)
  path_line=$(grep -n "^export PATH=" "$log" | tail -1 | cut -d: -f1)
  launch_line=$(grep -n "printf worker" "$log" | tail -1 | cut -d: -f1)
  [ -n "$task_line" ] || fail "spawn did not export FM_TASK_ID=$id"
  [ -n "$path_line" ] || fail "spawn did not export PATH"
  [ -n "$launch_line" ] || fail "spawn did not send its launch command"
  [ "$task_line" -lt "$path_line" ] || fail "PATH prepend must follow FM_TASK_ID (task=$task_line path=$path_line)"
  [ "$path_line" -lt "$launch_line" ] || fail "PATH prepend must precede launch (path=$path_line launch=$launch_line)"
  grep -F "export PATH='$GUARD_DIR':\$PATH" "$log" >/dev/null \
    || fail "PATH export did not prepend the captain-contact guard: $(grep '^export PATH=' "$log")"
}

test_spawned_ship_and_scout_refuse_notify_ask() {
  local rec home proj wt fakebin log id out rc
  rec=$(prepare_spawn shark-ship)
  IFS='|' read -r home proj wt fakebin log id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$log" "$id" "$proj" --mode no-mistakes --yolo off) || {
    fail "ship spawn failed: $out"
  }
  assert_guard_precedes_launch "$log" "$id"
  reset_decoy
  out=$(replay "$log" 'exec sharkctl notify ask --wait' 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "spawned ship environment must refuse sharkctl notify ask (got: $out)"
  assert_contains "$out" "must not contact the captain with sharkctl notify" \
    "spawned ship refusal did not name notify"
  decoy_was_called && fail "spawned ship environment invoked sharkctl: $(cat "$DECOY_LOG")"

  rec=$(prepare_spawn shark-scout)
  IFS='|' read -r home proj wt fakebin log id <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$log" "$id" "$proj" --scout) || {
    fail "scout spawn failed: $out"
  }
  assert_guard_precedes_launch "$log" "$id"
  reset_decoy
  out=$(replay "$log" 'exec sharkctl notify ask --wait' 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "spawned scout environment must refuse sharkctl notify ask (got: $out)"
  decoy_was_called && fail "spawned scout environment invoked sharkctl: $(cat "$DECOY_LOG")"
  pass "spawned ship and scout environments refuse sharkctl notify ask"
}

test_filtered_launch_keeps_the_guard() {
  local rec home proj wt fakebin log id out rc
  rec=$(prepare_spawn shark-filter)
  IFS='|' read -r home proj wt fakebin log id <<EOF
$rec
EOF
  : > "$home/config/launch-env-allowlist"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$log" "$id" "$proj" --mode no-mistakes --yolo off) || {
    fail "filtered ship spawn failed: $out"
  }
  assert_guard_precedes_launch "$log" "$id"
  # shellcheck disable=SC2016  # The launch text keeps this expansion for the pane shell.
  grep -F '${PATH+"PATH=$PATH"}' "$log" >/dev/null \
    || fail "filtered launch did not retain PATH from the pane"
  reset_decoy
  # The allowlist launch is `env -i` plus the names the pane expands, including
  # PATH and FM_TASK_ID. Replay the exports, then cross that same boundary.
  # shellcheck disable=SC2016  # The pane shell expands these after the exports land.
  out=$(replay "$log" 'exec /usr/bin/env -i ${PATH+"PATH=$PATH"} ${FM_TASK_ID+"FM_TASK_ID=$FM_TASK_ID"} ${DECOY_LOG+"DECOY_LOG=$DECOY_LOG"} sharkctl notify ask --wait' 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "filtered spawned environment must refuse sharkctl notify ask (got: $out)"
  decoy_was_called && fail "filtered spawned environment invoked sharkctl: $(cat "$DECOY_LOG")"
  pass "filtered launch keeps the guard and refuses sharkctl notify ask"
}

test_notify_ask_refuses_without_calling_sharkctl
test_ask_refuses_and_other_verbs_delegate
test_unmarked_shell_delegates_notify_ask
test_two_guard_aliases_delegate_once
test_spawned_ship_and_scout_refuse_notify_ask
test_filtered_launch_keeps_the_guard
