#!/usr/bin/env bash
# fm-board.sh - the opt-in live board: one web page of the fleet, read from
# its structured records, with answer buttons for what is waiting on the captain.
#
# Usage:
#   fm-board.sh serve
#   fm-board.sh status
#   fm-board.sh model [--snapshot-file <path>]
#   fm-board.sh answer <task-id> --card <digest> --choice <choice> \
#     [--until YYYY-MM-DD] [--text-file <path>|-] [--login <login>]
#   fm-board.sh unit
#
# Opt-in. Nothing here runs unless someone starts `serve` for a home, and a
# home that never does keeps every other behavior unchanged: no state, config,
# wake, or backlog record is created by merely having this script.
#
# serve    Run the board for the active FM_HOME in the foreground, bound to
#          127.0.0.1 only, through bin/fm-board.mjs (node; no npm dependency).
#          The page asks for data every FM_BOARD_INTERVAL seconds (default 10,
#          2..300). A rebuild from `model` runs only for a data request
#          that needs one: not while nobody is asking, and not again while the
#          backlog, heads-up notes, secondmate registry, task metadata, and
#          status logs are unchanged unless that rebuild started at least
#          60 seconds ago (or FM_BOARD_INTERVAL, when that is longer), with a
#          small margin so the next check is not early. An answer always
#          rebuilds after its write, so the page never keeps the
#          question it just answered. While it runs it keeps a private serve record,
#          state/board/serve.json (pid, port, instance), removed on exit.
#          bin/fm-board.mjs owns the persistent answer-confirmation records.
# status   Exit 0 and print the local URL when this home's board answers its
#          health check; exit 1 and say why otherwise. Reads only.
# model    Print the board's fm-board.v1 view as JSON, built only from
#          bin/fm-fleet-snapshot.sh --json (or --snapshot-file, for fixtures)
#          plus the curated notes file data/board-notes.json. A held item
#          whose snapshot hold_answer shows the captain already answered it
#          without releasing it is listed under with_lead, without buttons,
#          until the lead re-holds it. Recently done
#          is selected by the shared landed rule in bin/fm-landed-lib.sh. It never reads
#          backlog, status, or metadata files itself. Read-only.
# answer   Record one captain answer the board received. The server calls this
#          after its own request checks; it is not an operator command, and
#          the lead keeps using bin/fm-captain-hold.sh directly.
# unit     Print a systemd user unit that runs `serve` for this home. It only
#          prints; installing and enabling it is the operator's choice.
#
# WHAT A BOARD ANSWER IS. The captain's recorded words and nothing more. A
# Yes, No, declared option, or typed reply is fed to the one keyed-answer
# intake (`bin/fm-captain-hold.sh answers --source "live board..."`), so it is
# recorded exactly like every other channel. Later is recorded the same way and
# then re-holds the task with `hold --until <date>`, keeping its reason and
# declared options, so it leaves the live list and comes back on that date; it
# closes nothing.
# Every recorded answer then queues one captain inbox note through
# `bin/fm-inbox.sh note`, which appends the ordinary `check` wake, so the lead
# acts on it at its next turn. Nothing here merges, spawns, steers, tears
# down, or otherwise changes the fleet; the lead applies every authority rule
# when it acts on the answer.
#
# The card's close mode is declared by the board for every card it renders,
# from the structured row: a question row (kind captain) closes, and any other
# held work item is released so it can proceed, which keeps an approval from
# ever marking unlanded work complete. Only Yes releases held work: No, a
# declared option, a typed reply, and Later on a held work item use the
# intake's `record` mode, which keeps the hold, so the merge entrypoints keep
# refusing that work until the lead acts on the recorded choice. A card is
# pinned by a digest of the exact question shown (id, title, reason, hold-set
# stamp, hold-until, declared options, kind); `answer` holds the task's control
# lock from that check through its last captain-hold write, so a question
# re-asked while the page was open, or while the answer is being written, is
# never answered with the old click.
#
# answer prints exactly one JSON line, {"ok":true,"outcome":...,"message":...}
# or {"ok":false,"code":...,"message":...}, and exits 0 when recorded (a Later
# whose deferral fails after its answer was recorded verifies a repair intake
# write before reporting not_deferred and waking the lead; a failed repair
# still wakes the lead and returns repair_failed instead of success), 2 for an
# invalid request, 3 when the item is no longer the one the captain saw, and 1
# when recording failed. Free text is at most 500 characters and becomes one
# line; dates must be after today (UTC) and at most 366 days out.
#
# Configuration (all optional, local, gitignored, never inherited by
# secondmate homes; docs/configuration.md "Live board" owns the schema):
#   config/board-port    FM_BOARD_PORT   loopback port, default 8795
#   config/board-hosts   extra host names the page may be reached by; needs
#                        config/board-logins, or `serve` refuses to start
#   config/board-logins  Tailscale logins allowed through tailscale serve;
#                        without it only direct loopback requests are served
# docs/live-board.md owns setup, exposure, and the threat model.
#
# Environment:
#   FM_HOME              operational home whose records are shown.
#   FM_BOARD_PORT        overrides config/board-port; 0 picks a free port.
#   FM_BOARD_INTERVAL    seconds between page checks, default 10 (2..300).
#   FM_BOARD_TODAY       UTC date used to validate Later dates (tests only).
#   FM_BOARD_TEST_FULL_INTERVAL
#                        shortens the 60-second full rebuild bound (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

# shellcheck source=bin/fm-landed-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-landed-lib.sh"

BOARD_SCHEMA=fm-board.v1
DEFAULT_PORT=8795
TEXT_MAX_CHARS=500

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-board: %s\n' "$*" >&2
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

# Every value line of a config file: not blank and not a # comment.
config_lines() {  # <file-name>
  local path="$CONFIG/$1" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done < "$path"
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

lead_name() {
  local name
  name=$("$SCRIPT_DIR/fm-persona-lib.sh" --role lead 2>/dev/null) || name=''
  [ -n "$name" ] || name='the lead'
  printf '%s' "$name"
}

home_label() {
  local marker="$FM_HOME/.fm-secondmate-home" label
  [ -f "$marker" ] || return 0
  label=$(head -1 "$marker" 2>/dev/null | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
  printf '%s' "$label"
}

resolve_port() {
  local port=${FM_BOARD_PORT:-}
  [ -n "$port" ] || port=$(config_lines board-port | head -1)
  [ -n "$port" ] || port=$DEFAULT_PORT
  case "$port" in
    ''|*[!0-9]*) fail "board port must be a number: $port (FM_BOARD_PORT or $CONFIG/board-port)" ;;
  esac
  [ "${#port}" -le 5 ] && [ "$port" -le 65535 ] \
    || fail "board port must be 0..65535: $port (FM_BOARD_PORT or $CONFIG/board-port)"
  printf '%s' "$port"
}

# ---------------------------------------------------------------- model

NOTES_JSON='[]'
NOTES_ERRORS='[]'

# The curated notes file, reduced to its documented shape, into NOTES_JSON. A
# missing file is simply no notes; an unreadable one is reported in
# NOTES_ERRORS so the board shows it rather than hiding it.
load_notes() {
  local path="$DATA/board-notes.json" notes dropped
  NOTES_JSON='[]'
  NOTES_ERRORS='[]'
  [ -e "$path" ] || return 0
  if ! jq empty "$path" >/dev/null 2>&1; then
    NOTES_ERRORS='["The heads-up notes file data/board-notes.json is not valid JSON."]'
    return 0
  fi
  if ! notes=$(jq -c '
      def trunc($n): if length > $n then .[:$n] + "…" else . end;
      def web_link: type == "string" and test("^https?://[^[:space:]\"<>]+$");
      if type != "array" then null
      else
        {kept: [ .[]
          | select(type == "object" and (.text | type) == "string" and (.text | length) > 0)
          | {kind: (if .kind == "you" then "you" else "fyi" end),
             text: (.text | trunc(500)),
             detail: (if (.detail | type) == "string" and (.detail | length) > 0 then .detail | trunc(2000) else null end),
             link: (if (.link | web_link) then .link else null end)} ],
         total: length}
        | .dropped = (.total - (.kept | length))
      end' "$path" 2>/dev/null) || [ "$notes" = null ]; then
    NOTES_ERRORS='["The heads-up notes file data/board-notes.json must be a JSON list of notes."]'
    return 0
  fi
  dropped=$(printf '%s' "$notes" | jq '.dropped')
  if [ "$dropped" -gt 0 ]; then
    NOTES_ERRORS=$(jq -cn --argjson n "$dropped" \
      '["\($n) heads-up note(s) were skipped because they are not in the expected shape."]')
  fi
  NOTES_JSON=$(printf '%s' "$notes" | jq -c '.kept')
}

# Pure projection of one snapshot plus notes into the board view, without the
# card digests (added by build_model so the digest has one owner).
project_model() {  # <snapshot-file> <notes-json> <errors-json>
  jq -c --slurpfile snap "$1" --argjson notes "$2" --argjson errors "$3" \
    --arg schema "$BOARD_SCHEMA" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lead "$(lead_name)" --arg product shuvbro --arg home_label "$(home_label)" -n "$FM_LANDED_JQ_DEFS"'
    def trunc($n): if type == "string" and length > $n then .[:$n] + "…" else . end;
    def text_or_null: if type == "string" and length > 0 then . else null end;
    def web_link: type == "string" and test("^https?://[^[:space:]\"<>]+$");
    def base: if type == "string" then (split("/") | map(select(. != "")) | last) else null end;
    def friendly($t):
      ($t.current_state.state // "unknown") as $s
      | ($t.current_state.source // "") as $src
      | (($t.current_state.detail // "") | ascii_downcase) as $d
      | (((($t.hints.open_decisions // []) | length) > 0) or ($t.hints.pending_decision == true)) as $deciding
      | if $s == "failed" then {label: "Failed", tone: "blocked"}
        elif $s == "dead" or $s == "missing" or $s == "gone" then {label: "Stopped responding", tone: "blocked"}
        elif $deciding then {label: "Decision pending, \($lead) is on it", tone: "decision"}
        elif $s == "working" then
          (if $src == "run-step" or ($d | test("validat|checks")) then {label: "In automated review", tone: "review"}
           else {label: "Working", tone: "working"} end)
        elif $s == "parked" then {label: "Review step needs a call, \($lead) is on it", tone: "decision"}
        elif $s == "done" then
          (if ($t.pr.url | web_link) then
             (if ($d | test("checks green|checks passed|checks-passed")) then {label: "PR ready, checks passing", tone: "ready"}
              else {label: "PR ready", tone: "ready"} end)
           else {label: "Finished, wrapping up", tone: "ready"} end)
        elif $s == "blocked" then {label: "Stuck, \($lead) is on it", tone: "blocked"}
        elif $s == "paused" then {label: "Waiting on an outside event", tone: "paused"}
        elif $s == "idle" then {label: "Idle", tone: "paused"}
        elif $s == "unknown" then {label: "Status unknown", tone: "unknown"}
        else {label: ($s | gsub("[-_]"; " ") | (.[:1] | ascii_upcase) + .[1:]), tone: "unknown"} end;
    ($snap[0]) as $snap
    | [ ($snap.backlog.records // [])[] | select(.structured == true) ] as $records
    | (reduce $records[] as $r ({}; .[$r.id] = $r)) as $by_id
    | [ $records[]
        | select(.hold_kind == "captain" and (.hold_bucket == "live" or .hold_bucket == "aged")) ] as $open_holds
    | [ $open_holds[]
        | select(.hold_answer == null)
        | {id,
           source: "backlog",
           answerable: true,
           aged: (.hold_bucket == "aged"),
           title: ((.title // .id) | trunc(300)),
           reason: (.hold_reason | text_or_null),
           repo: (.repo | text_or_null),
           age_days: .hold_age_days,
           links: [ (.links // [])[] | select(web_link) ],
           choices: (if (.hold_options | type) == "array" and (.hold_options | length) > 0
                     then [ .hold_options | to_entries[] | {id: "opt-\(.key + 1)", label: .value} ]
                     else [ {id: "yes", label: "Yes"}, {id: "no", label: "No"} ] end),
           answer_mode: (if .kind == "captain" then "done" else "release" end),
           _core: {id, title, reason: .hold_reason, hold_set, hold_until, options: .hold_options, kind}} ] as $held
    | [ $notes[] | select(.kind == "you")
        | {id: null, source: "note", answerable: false, aged: false, title: .text, reason: .detail,
           repo: null, age_days: null, links: [ .link | select(. != null) ]} ] as $you_notes
    | [ ($snap.secondmate_current.records // [])[]
        | .id as $mate
        | (.decisions_open // [])[]
        | select(.verb == "captain-hold")
        | {id, source: "secondmate", from: $mate, answerable: false, aged: false,
           title: ((.summary // .id) | trunc(300)), reason: (.reason | text_or_null),
           repo: null, age_days: (.hold_age_days // null), links: []} ] as $mate_holds
    | {
        schema: $schema,
        generated: $now,
        snapshot_generated: ($snap.generated // null),
        product: $product,
        lead: $lead,
        home_label: ($home_label | text_or_null),
        waiting_on_you: ([ $held[] | select(.aged | not) ] + $you_notes + $mate_holds + [ $held[] | select(.aged) ]),
        with_lead: [ $open_holds[]
          | select(.hold_answer != null)
          | {id,
             title: ((.title // .id) | trunc(300)),
             reason: (.hold_reason | text_or_null),
             repo: (.repo | text_or_null),
             links: [ (.links // [])[] | select(web_link) ],
             answer: (.hold_answer.answer | text_or_null | trunc(500)),
             answered_at: .hold_answer.at} ],
        in_flight: [ ($snap.tasks // [])[]
          | . as $t
          | ($by_id[$t.id] // {}) as $row
          | friendly($t) as $f
          | {id,
             title: (($row.title // .id) | trunc(300)),
             project: (.project | base),
             kind: (if .kind == "scout" then "scout" elif .kind == "secondmate" then "second mate" else null end),
             label: $f.label,
             tone: $f.tone,
             observed_at: (.current_state.observed_at // null),
             pr: (if (.pr.url | web_link) then .pr.url else null end),
             note: (.hints.last_event_text | text_or_null | trunc(600))} ],
        queued: [ $records[]
          | select(.state == "queued")
          | select((.hold_kind == "captain" and (.hold_bucket == "live" or .hold_bucket == "aged")) | not)
          | {id,
             title: ((.title // .id) | trunc(300)),
             repo: (.repo | text_or_null),
             links: [ (.links // [])[] | select(web_link) ],
             note: (([ (.unresolved_blocker_ids // [])[] | ($by_id[.].title // .) ] | join(", ")) as $after
               | if .hold_kind == "captain" and .hold_bucket == "dated" then "back to you on \(.hold_until)"
                    elif .hold_kind == "captain" and .hold_bucket == "blocked" then "back to you after \($after)"
                    elif $after != "" then "after \($after)"
                    elif .hold_reason != null then "on hold: \(.hold_reason)"
                    else null end)} ],
        done: ([ $records[] | select(landed_record) ][:12]
          | map({id,
                 title: ((.title // .id) | trunc(300)),
                 repo: (.repo | text_or_null),
                 pr: (if (.pr_url | web_link) then .pr_url else null end),
                 verb: (.completion.verb // null),
                 date: (.completion.date // null)})),
        fyi: [ $notes[] | select(.kind != "you") | {text, detail, link} ],
        errors: $errors
      }'
}

MODEL_SNAPSHOT_FILE=
MODEL_SNAPSHOT_OWNED=0
MODEL_JSON=

# The full view, into MODEL_JSON: projection plus one digest per answerable
# card. Without a snapshot file it takes a fresh snapshot into a private
# temporary file named by MODEL_SNAPSHOT_FILE, which model_cleanup removes.
# Called directly, never in a command substitution, so those globals reach the
# caller.
build_model() {  # [<snapshot-file>]
  local snapshot=${1:-} model cards='{}' key b64 digest
  MODEL_JSON=
  if [ -z "$snapshot" ]; then
    MODEL_SNAPSHOT_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-board-snapshot.XXXXXX") \
      || { printf 'fm-board: cannot stage the fleet snapshot\n' >&2; return 1; }
    MODEL_SNAPSHOT_OWNED=1
    if ! "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$MODEL_SNAPSHOT_FILE" 2>/dev/null \
      || ! jq -e 'type == "object" and .schema == "fm-fleet-snapshot.v1"' "$MODEL_SNAPSHOT_FILE" >/dev/null 2>&1; then
      printf 'fm-board: the fleet snapshot could not be read\n' >&2
      return 1
    fi
    snapshot=$MODEL_SNAPSHOT_FILE
  else
    [ -r "$snapshot" ] || { printf 'fm-board: snapshot file is not readable: %s\n' "$snapshot" >&2; return 1; }
    MODEL_SNAPSHOT_FILE=$snapshot
    MODEL_SNAPSHOT_OWNED=0
  fi
  load_notes
  model=$(project_model "$snapshot" "$NOTES_JSON" "$NOTES_ERRORS") || return 1
  while IFS="$(printf '\t')" read -r key b64; do
    [ -n "$key" ] || continue
    digest=$(sha256_text "$b64")
    cards=$(printf '%s' "$cards" | jq -c --arg k "$key" --arg d "$digest" '.[$k] = $d')
  done <<CARDS
$(printf '%s' "$model" | jq -r '.waiting_on_you | to_entries[] | select(.value.answerable) | [(.key | tostring), (.value._core | tojson | @base64)] | @tsv')
CARDS
  MODEL_JSON=$(printf '%s' "$model" | jq -c --argjson cards "$cards" '
    .waiting_on_you |= [ to_entries[]
      | .value + (if $cards[.key | tostring] then {card: $cards[.key | tostring]} else {} end)
      | del(._core) ]')
}

model_cleanup() {
  if [ "$MODEL_SNAPSHOT_OWNED" = 1 ] && [ -n "$MODEL_SNAPSHOT_FILE" ]; then
    rm -f -- "$MODEL_SNAPSHOT_FILE"
  fi
  MODEL_SNAPSHOT_OWNED=0
}

command_model() {
  local snapshot=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot-file) shift; snapshot=${1:-}; [ -n "$snapshot" ] || { usage >&2; exit 2; } ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  need jq
  trap model_cleanup EXIT
  build_model "$snapshot" || exit 1
  printf '%s\n' "$MODEL_JSON"
}

# ---------------------------------------------------------------- answer

# One JSON result line and the matching exit status.
answer_result() {  # <exit> <code-or-outcome> <message> [<note-id>] [<task-id>]
  local status=$1 code=$2 message=$3 note=${4:-} task=${5:-}
  if [ "$status" = 0 ]; then
    jq -cn --arg outcome "$code" --arg message "$message" --arg note "$note" --arg task "$task" \
      '{ok: true, outcome: $outcome, task: $task, message: $message, note: ($note | if . == "" then null else . end)}'
  else
    jq -cn --arg code "$code" --arg message "$message" '{ok: false, code: $code, message: $message}'
  fi
  model_cleanup
  exit "$status"
}

valid_until() {  # <YYYY-MM-DD> <today>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) return 1 ;;
  esac
  jq -en --arg d "$1" --arg t "$2" '
    (try (($d + "T00:00:00Z") | fromdateiso8601) catch null) as $a
    | (try (($t + "T00:00:00Z") | fromdateiso8601) catch null) as $b
    | $a != null and $b != null
      and (($a | todate)[:10] == $d)
      and $a > $b and ($a - $b) <= (366 * 86400)' >/dev/null
}

ANSWER_LOCK=
ANSWER_LOCK_PID=

# The task control lock bin/fm-captain-hold.sh takes for every write to a
# captain call. Its holder's pid, passed as FM_CAPTAIN_HOLD_LOCKED_BY, lets the
# captain-hold writes this answer makes run inside it instead of waiting on it.
answer_lock_acquire() {  # <task-id>
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_current_pid ANSWER_LOCK_PID || return 1
  ANSWER_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait "$ANSWER_LOCK" || { ANSWER_LOCK=; return 1; }
}

answer_lock_release() {
  [ -n "$ANSWER_LOCK" ] || return 0
  fm_lock_release "$ANSWER_LOCK" || true
  ANSWER_LOCK=
}

command_answer() {
  local id=${1:-} card='' choice='' until='' text_file='' login='' text='' have_text=0
  local item lead source label answer_value mode intake_mode reason title outcome rc out note_body note_out note_id
  local today summary defer_error='' option
  trap 'model_cleanup; answer_lock_release' EXIT
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --card) shift; card=${1:-} ;;
      --choice) shift; choice=${1:-} ;;
      --until) shift; until=${1:-} ;;
      --text-file) shift; text_file=${1:-}; have_text=1 ;;
      --login) shift; login=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  need jq
  lead=$(lead_name)
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) answer_result 2 unknown_task "That item is not on the board." ;;
  esac
  [ "${#id}" -le 128 ] || answer_result 2 unknown_task "That item is not on the board."
  case "$card" in
    *[!0-9a-f]*|'') answer_result 2 bad_request "The request did not name the question it answers." ;;
  esac
  [ "${#card}" -eq 64 ] || answer_result 2 bad_request "The request did not name the question it answers."
  case "$choice" in
    yes|no|later|reply|opt-[1-6]) : ;;
    *) answer_result 2 bad_choice "That answer is not offered for this question." ;;
  esac
  if [ -n "$login" ]; then
    case "$login" in
      *[!A-Za-z0-9._%+@:-]*) answer_result 2 bad_request "The signed-in login could not be recorded." ;;
    esac
    [ "${#login}" -le 128 ] || answer_result 2 bad_request "The signed-in login could not be recorded."
  fi
  if [ "$have_text" = 1 ]; then
    if [ "$text_file" = - ]; then
      text=$(cat)
    else
      [ -r "$text_file" ] || answer_result 2 bad_text "Write a reply of 1 to $TEXT_MAX_CHARS characters."
      text=$(cat -- "$text_file")
    fi
    # One line, so the intake's tab-separated record cannot be split or forged.
    text=$(printf '%s' "$text" | tr '\r\n\t' '   ' | tr -s ' ')
    text=${text#"${text%%[![:space:]]*}"}
    text=${text%"${text##*[![:space:]]}"}
    if printf '%s' "$text" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      answer_result 2 bad_text "The reply contains characters the board cannot record."
    fi
  fi
  if [ "$choice" = reply ]; then
    [ -n "$text" ] || answer_result 2 bad_text "Write a reply of 1 to $TEXT_MAX_CHARS characters."
    [ "$(printf '%s' "$text" | jq -Rs 'length')" -le "$TEXT_MAX_CHARS" ] \
      || answer_result 2 text_too_long "Write a reply of 1 to $TEXT_MAX_CHARS characters."
    [ "$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')" != reconcile ] \
      || answer_result 2 reserved "\"reconcile\" is reserved here. Add a few words so it reads as your answer."
  elif [ -n "$text" ]; then
    answer_result 2 bad_request "Only a typed reply carries text."
  fi
  today=${FM_BOARD_TODAY:-$(date -u +%Y-%m-%d)}
  if [ "$choice" = later ]; then
    valid_until "$until" "$today" || answer_result 2 bad_date "Pick a date after today and within a year."
  elif [ -n "$until" ]; then
    answer_result 2 bad_request "Only Later carries a date."
  fi

  answer_lock_acquire "$id" \
    || answer_result 1 record_failed "The board could not lock this item, so nothing was recorded."
  build_model || answer_result 1 snapshot_failed "The board could not read the fleet records, so nothing was recorded."
  item=$(printf '%s' "$MODEL_JSON" | jq -c --arg id "$id" \
    'first(.waiting_on_you[] | select(.answerable and .id == $id)) // empty')
  if [ -z "$item" ]; then
    if jq -e --arg id "$id" 'any((.backlog.records // [])[]; .structured == true and .id == $id)' \
      "$MODEL_SNAPSHOT_FILE" >/dev/null; then
      answer_result 3 not_waiting "This is no longer waiting on you."
    fi
    answer_result 2 unknown_task "That item is not on the board."
  fi
  [ "$(printf '%s' "$item" | jq -r '.card')" = "$card" ] \
    || answer_result 3 stale_card "This question changed since the page loaded. Review it again."

  title=$(printf '%s' "$item" | jq -r '.title // ""')
  reason=$(printf '%s' "$item" | jq -r '.reason // ""')
  mode=$(printf '%s' "$item" | jq -r '.answer_mode')
  case "$choice" in
    later|reply) label='' ;;
    *)
      label=$(printf '%s' "$item" | jq -r --arg c "$choice" 'first(.choices[] | select(.id == $c) | .label) // empty')
      [ -n "$label" ] || answer_result 2 bad_choice "That answer is not offered for this question."
      ;;
  esac

  rc=0
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) : ;;
    1|3) answer_result 3 not_waiting "This is no longer waiting on you." ;;
    *) answer_result 1 record_failed "The board could not confirm this is still waiting on you, so nothing was recorded." ;;
  esac

  source='live board'
  [ -z "$login" ] || source="live board, signed in as $login"

  case "$mode:$choice" in
    release:yes) intake_mode=release ;;
    release:*|*:later) intake_mode=record ;;
    *) intake_mode=$mode ;;
  esac
  case "$choice" in
    later)
      answer_value="later, until $until"
      summary="Later, until $until"
      label="Later, until $until - in reply to: $reason"
      ;;
    reply)
      answer_value=$text
      summary="typed reply"
      label="Typed reply - in reply to: $reason"
      ;;
    *)
      case "$choice" in
        yes) answer_value=yes ;;
        no) answer_value=no ;;
        *) answer_value=$label ;;
      esac
      summary=$label
      label="$label - in reply to: $reason"
      ;;
  esac
  label=$(printf '%s' "$label" | tr '\t\r\n' '   ')
  feed_intake() {
    printf '%s\t%s\t%s\t%s\n' "$id" "$answer_value" "$label" "$intake_mode" \
      | FM_CAPTAIN_HOLD_LOCKED_BY=$ANSWER_LOCK_PID "$SCRIPT_DIR/fm-captain-hold.sh" answers --source "$source" 2>/dev/null
  }
  out=$(feed_intake) || true
  if ! printf '%s\n' "$out" | grep -Fxq -e "closed: $id" -e "recorded: $id"; then
    answer_result 1 record_failed "Not recorded: $(printf '%s\n' "$out" | grep -F "$id" | head -1 | sed 's/^[a-z]*: [^ ]* //; s/^(//; s/)$//' | cut -c1-300)"
  fi
  case "$intake_mode" in
    release) outcome=released ;;
    record) outcome=recorded ;;
    *) outcome=closed ;;
  esac

  if [ "$choice" = later ]; then
    set -- hold "$id" --reason "$reason" --until "$until"
    while IFS= read -r option; do
      [ -n "$option" ] || continue
      set -- "$@" --option "$option"
    done <<EOF
$(printf '%s' "$item" | jq -r 'if .choices[0].id == "yes" then empty else .choices[].label end')
EOF
    if out=$(FM_CAPTAIN_HOLD_LOCKED_BY=$ANSWER_LOCK_PID "$SCRIPT_DIR/fm-captain-hold.sh" "$@" 2>&1 </dev/null); then
      outcome=deferred
    else
      outcome=not_deferred
      defer_error=$(printf '%s' "$out" | tail -1 | sed 's/^fm-captain-hold: //' | cut -c1-300)
      # Record the failed date gate as new provenance, not an idempotent replay
      # of the original Later. Its recovery write must actually land.
      source="$source, date could not be set"
      out=$(feed_intake) || true
      printf '%s\n' "$out" | grep -Fxq "recorded: $id" || outcome=repair_failed
    fi
  fi

  answer_lock_release
  note_body=$(
    printf 'Live board answer for %s: %s\n' "$id" "$summary"
    printf 'Question: %s' "$title"
    [ -z "$reason" ] || printf ' - %s' "$reason"
    printf '\n'
    [ "$choice" != reply ] || printf 'Reply: %s\n' "$answer_value"
    case "$outcome" in
      closed) printf 'Recorded through the %s: the question is closed with this answer.\n' "$source" ;;
      released) printf 'Recorded through the %s: the held work is released with this answer.\n' "$source" ;;
      recorded) printf 'Recorded through the %s: the held work stays held until you act on this answer.\n' "$source" ;;
      deferred) printf 'Recorded through the %s: deferred until %s; it returns to the captain then.\n' "$source" "$until" ;;
      not_deferred) printf 'Recorded through the %s, but deferring until %s failed (%s); the work stays held, so re-hold it with that date.\n' "$source" "$until" "$defer_error" ;;
      repair_failed) printf 'Later was recorded through the %s, but deferring until %s failed (%s) and the follow-up record did not land, so the outcome is uncertain; the work stays held: check the task, then re-hold it with that date or ask the captain.\n' "$source" "$until" "$defer_error" ;;
    esac
  )
  if [ "$outcome" = repair_failed ]; then
    if ! printf '%s\n' "$note_body" | "$SCRIPT_DIR/fm-inbox.sh" note - >/dev/null 2>&1; then
      answer_result 1 repair_failed "Later was recorded, but the date and follow-up could not be confirmed. $lead was not notified. Mention it in chat; the work stays held."
    fi
    answer_result 1 repair_failed "Later could not be confirmed after the date failed. The work stays held. Refresh or ask $lead before answering again."
  fi
  if ! note_out=$(printf '%s\n' "$note_body" | "$SCRIPT_DIR/fm-inbox.sh" note - 2>&1); then
    answer_result 0 "$outcome" "Recorded, but $lead was not notified. Mention it in chat." '' "$id"
  fi
  note_id=$(printf '%s\n' "$note_out" | sed -n 's/^queued //p' | head -1)
  if [ "$outcome" = deferred ]; then
    answer_result 0 "$outcome" "Moved to $until. It comes back to you then." "$note_id" "$id"
  fi
  if [ "$outcome" = not_deferred ]; then
    answer_result 0 "$outcome" "Recorded, but it could not be moved to $until. $lead will pick it up." "$note_id" "$id"
  fi
  answer_result 0 "$outcome" "Recorded. $lead will pick it up." "$note_id" "$id"
}

# ---------------------------------------------------------------- serve / status / unit

command_serve() {
  local port hosts logins interval host login config
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  need node
  need jq
  port=$(resolve_port)
  interval=${FM_BOARD_INTERVAL:-10}
  case "$interval" in
    ''|*[!0-9]*) fail "FM_BOARD_INTERVAL must be a whole number of seconds: $interval" ;;
  esac
  [ "$interval" -ge 2 ] && [ "$interval" -le 300 ] || fail "FM_BOARD_INTERVAL must be 2..300 seconds: $interval"
  hosts='[]'
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    case "$host" in
      *[!a-z0-9.-]*|.*|*.) fail "invalid host name in $CONFIG/board-hosts: $host (one bare host name per line)" ;;
    esac
    hosts=$(printf '%s' "$hosts" | jq -c --arg h "$host" '. + [$h]')
  done <<EOF
$(config_lines board-hosts)
EOF
  logins='[]'
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    case "$login" in
      *[!A-Za-z0-9._%+@:-]*) fail "invalid login in $CONFIG/board-logins: $login (one Tailscale login per line)" ;;
    esac
    logins=$(printf '%s' "$logins" | jq -c --arg l "$login" '. + [$l]')
  done <<EOF
$(config_lines board-logins)
EOF
  [ "$hosts" = '[]' ] || [ "$logins" != '[]' ] \
    || fail "$CONFIG/board-hosts lists host names but $CONFIG/board-logins is empty; list your Tailscale login there before sharing the board, or remove board-hosts to keep it on this computer only"
  config=$(jq -cn \
    --arg home "$FM_HOME" --arg state "$STATE" --arg data "$DATA" --arg board_sh "$SCRIPT_DIR/fm-board.sh" \
    --arg page "$SCRIPT_DIR/fm-board-page.html" --argjson port "$port" --argjson interval "$interval" \
    --argjson hosts "$hosts" --argjson logins "$logins" \
    '{home: $home, state_dir: $state, data_dir: $data, board_sh: $board_sh, page: $page, port: $port,
      interval: $interval, hosts: $hosts, logins: $logins}')
  FM_BOARD_SERVE_CONFIG=$config exec node "$SCRIPT_DIR/fm-board.mjs"
}

command_status() {
  local record="$STATE/board/serve.json" pid port url
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  if [ ! -f "$record" ]; then
    printf 'not serving: no board is running for %s\n' "$FM_HOME"
    exit 1
  fi
  need jq
  pid=$(jq -r '.pid // empty' "$record" 2>/dev/null || true)
  port=$(jq -r '.port // empty' "$record" 2>/dev/null || true)
  case "$pid:$port" in
    *[!0-9:]*|:*|*:) printf 'not serving: the board record is unreadable: %s\n' "$record"; exit 1 ;;
  esac
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'not serving: the board record names process %s, which is not running\n' "$pid"
    exit 1
  fi
  url="http://127.0.0.1:$port/"
  need node
  if node -e '
    const req = require("http").get(process.argv[1] + "healthz", { timeout: 3000 }, (res) => {
      process.exit(res.statusCode === 200 ? 0 : 1);
    });
    req.on("timeout", () => { req.destroy(); process.exit(1); });
    req.on("error", () => process.exit(1));
  ' "$url"; then
    printf 'serving: %s (pid %s)\n' "$url" "$pid"
    exit 0
  fi
  printf 'not serving: process %s holds the board record but %s does not answer\n' "$pid" "$url"
  exit 1
}

# systemd reads % as a specifier and needs quotes around values with spaces.
unit_value() {  # <text>
  printf '%s' "$1" | sed -e 's/%/%%/g' -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

command_unit() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  cat <<EOF
[Unit]
Description=shuvbro live board for $(unit_value "$FM_HOME")
After=network.target

[Service]
Type=simple
Environment="FM_HOME=$(unit_value "$FM_HOME")"
Environment="PATH=$(unit_value "$PATH")"
ExecStart="$(unit_value "$SCRIPT_DIR/fm-board.sh")" serve
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
}

case "${1:-}" in
  serve) shift; command_serve "$@" ;;
  status) shift; command_status "$@" ;;
  model) shift; command_model "$@" ;;
  answer) shift; command_answer "$@" ;;
  unit) shift; command_unit "$@" ;;
  ''|-h|--help|help) usage ;;
  *) printf 'fm-board: unknown subcommand: %s (try --help)\n' "$1" >&2; exit 2 ;;
esac
