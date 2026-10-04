#!/usr/bin/env bash
# Behavior tests for the opt-in live board (bin/fm-board.sh with its loopback
# server bin/fm-board.mjs): the view rendered from a fixture snapshot and the
# curated notes file, the request guard on the page, data, and answer
# endpoints, every answer kind landing through the captain-hold keyed-answer
# intake with board provenance plus one captain inbox wake, and a home that
# never opts in staying untouched. Every server binds 127.0.0.1 on a free port
# inside a disposable home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)
BOARD_PIDS="$TMP_ROOT/board-pids"
: > "$BOARD_PIDS"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

stop_boards() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done < "$BOARD_PIDS"
  : > "$BOARD_PIDS"
}
trap 'stop_boards; fm_test_cleanup' EXIT
trap 'stop_boards; fm_test_cleanup; exit 130' INT
trap 'stop_boards; fm_test_cleanup; exit 143' TERM

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-ship - Ship the sample widget (repo: sample) (kind: ship) (since 2026-07-01)
- [ ] sample-plain - Plain queued work (repo: sample) (kind: ship) (since 2026-07-01)

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

hold() {  # <home> <task-id> <args...>
  local home=$1
  shift
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$@" >/dev/null \
    || fail "could not hold $2 for the captain"
}

task_show() {  # <home> <task-id>
  (cd "$1" && tasks-axi show "$2" --full)
}

# local_merge_refused <home> <task-id>: a local-only delivery for the task is
# staged and bin/fm-merge-local.sh must refuse it without moving main.
local_merge_refused() {
  local home=$1 id=$2 repo wt before rc=0
  repo="$home/projects/$id-repo"
  wt="$home/projects/$id"
  if [ ! -d "$wt" ]; then
    fm_git_worktree "$repo" "$wt" "fm/$id"
    printf 'held delivery\n' > "$wt/local.txt"
    git -C "$wt" add local.txt
    git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'held delivery'
    fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
      "project=$repo" "harness=codex" "kind=ship" "mode=local-only" "spawn_gen=fixture-$id"
  fi
  before=$(git -C "$repo" rev-parse main)
  in_home "$home" "$ROOT/bin/fm-merge-local.sh" "$id" > "$home/$id-merge.out" 2> "$home/$id-merge.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted $id after a board answer that keeps it held"
  [ "$(git -C "$repo" rev-parse main)" = "$before" ] || fail "the local merge entrypoint moved main for held $id"
  grep -F "$id is still held for the captain" "$home/$id-merge.err" >/dev/null \
    || fail "the local merge refusal did not name held $id: $(cat "$home/$id-merge.err")"
}

utc_day() {  # <offset-days>
  node -e 'console.log(new Date(Date.now() + Number(process.argv[1]) * 86400000).toISOString().slice(0, 10))' "$1"
}

BOARD_PORT=
BOARD_TOKEN=

start_board() {  # <home>
  local home=$1 i=0
  rm -f "$home/state/board/serve.json"
  (
    cd "$home" || exit 1
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOARD_PORT=0 FM_BOARD_INTERVAL=2 exec "$BOARD" serve
  ) > "$home/serve.log" 2>&1 &
  printf '%s\n' "$!" >> "$BOARD_PIDS"
  while [ ! -s "$home/state/board/serve.json" ]; do
    i=$((i + 1))
    [ "$i" -le 300 ] || fail "the board did not start: $(cat "$home/serve.log")"
    sleep 0.1
  done
  BOARD_PORT=$(jq -r '.port' "$home/state/board/serve.json")
  BOARD_TOKEN=$(http GET / '{}' | sed -n 's/.*name="fm-board-token" content="\([0-9a-f]*\)".*/\1/p' | head -1)
  [ "${#BOARD_TOKEN}" -eq 64 ] || fail "the served page carried no answer token"
}

# http <method> <path> <headers-json> [<body>] prints the status code, the
# response headers as one JSON line, then the body.
http() {
  # shellcheck disable=SC2016  # JavaScript template literals, not shell expansions.
  node -e '
    const [method, port, path, headers, body] = process.argv.slice(1);
    const req = require("http").request({ host: "127.0.0.1", port: Number(port), path, method, headers: JSON.parse(headers) }, (res) => {
      let text = "";
      res.on("data", (chunk) => { text += chunk; });
      res.on("end", () => process.stdout.write(`${res.statusCode}\n${JSON.stringify(res.headers)}\n${text}`));
    });
    req.on("error", (error) => process.stdout.write(`000\n{}\n${error.message}`));
    if (body) req.write(body);
    req.end();
  ' "$1" "$BOARD_PORT" "$2" "$3" "${4:-}"
}

status_of() { printf '%s\n' "$1" | sed -n '1p'; }
headers_of() { printf '%s\n' "$1" | sed -n '2p'; }
body_of() { printf '%s\n' "$1" | sed -n '3,$p'; }

local_origin() { printf 'http://127.0.0.1:%s' "$BOARD_PORT"; }

board_data() {
  body_of "$(http GET /board.json '{}')"
}

card_of() {  # <task-id>
  board_data | jq -r --arg id "$1" '.waiting_on_you[] | select(.answerable and .id == $id) | .card'
}

# post_answer <body-json> [<headers-json>] with same-origin defaults.
post_answer() {
  local body=$1 headers=${2:-}
  [ -n "$headers" ] || headers=$(jq -cn --arg o "$(local_origin)" '{"Content-Type": "application/json", Origin: $o}')
  http POST /answer "$headers" "$body"
}

answer_body() {  # <task-id> <choice> [<jq-extra-object>]
  jq -cn --arg t "$BOARD_TOKEN" --arg id "$1" --arg card "$(card_of "$1")" --arg c "$2" \
    --argjson extra "${3:-{\}}" '{token: $t, task: $id, card: $card, choice: $c} + $extra'
}

expect_refusal() {  # <response> <status> <code> <what>
  [ "$(status_of "$1")" = "$2" ] || fail "$4: expected HTTP $2, got $(status_of "$1"): $(body_of "$1")"
  [ "$(body_of "$1" | jq -r '.code')" = "$3" ] || fail "$4: expected code $3: $(body_of "$1")"
}

inbox_notes() {  # <home>
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

write_fixture_snapshot() {  # <path>
  jq -n '
    def row($id; $title; $state; $extra):
      {structured: true, id: $id, title: $title, state: $state, repo: "sample", kind: "ship",
       hold_reason: null, hold_kind: null, hold_until: null, hold_set: null, hold_options: null,
       hold_bucket: null, hold_age_days: null, captain_actionable: false,
       unresolved_blocker_ids: [], links: [], pr_url: null,
       completion: {verb: null, date: null}} + $extra;
    {schema: "fm-fleet-snapshot.v1", generated: "2026-07-25T00:00:00Z",
     backlog: {present: true, records: ([
       row("call-live"; "Close the duplicate PR?"; "queued";
         {kind: "captain", hold_reason: "Close duplicate PR 13? Recommend yes", hold_kind: "captain",
          hold_set: "2026-07-24T00:00:00Z", hold_bucket: "live", hold_age_days: 1, captain_actionable: true,
          links: ["https://github.com/sample/repo/pull/13", "javascript:alert(1)"]}),
       row("work-gated"; "Ship the widget"; "in_flight";
         {hold_reason: "Which rollout? Recommend staged", hold_kind: "captain", hold_set: "2026-07-24T00:00:00Z",
          hold_options: ["Staged", "All at once"], hold_bucket: "live", hold_age_days: 1, captain_actionable: true}),
       row("call-aged"; "An old question"; "queued";
         {kind: "captain", hold_reason: "Still want this?", hold_kind: "captain", hold_set: "2026-06-01T00:00:00Z",
          hold_bucket: "aged", hold_age_days: 54}),
       row("call-dated"; "A deferred question"; "queued";
         {kind: "captain", hold_reason: "Revisit later", hold_kind: "captain", hold_until: "2026-08-01",
          hold_bucket: "dated", hold_age_days: 3}),
       row("call-blocked"; "A gated question"; "queued";
         {kind: "captain", hold_reason: "After the migration", hold_kind: "captain", hold_bucket: "blocked",
          unresolved_blocker_ids: ["migration-task"]}),
       row("plain-queued"; "Plain queued work"; "queued"; {unresolved_blocker_ids: ["work-gated"]}),
       row("running-task"; "Running task"; "in_flight"; {})
     ] + [range(0; 13) as $i | row("done-\($i)"; "Done \($i)"; "done";
          {pr_url: "https://github.com/sample/repo/pull/\(100 + $i)", completion: {verb: "merged", date: "2026-07-2\($i % 10)"}})])},
     tasks: [
       {id: "running-task", kind: "ship", project: "/tmp/projects/sample",
        current_state: {state: "working", source: "run-step", detail: "review running", observed_at: "2026-07-25T00:00:00Z"},
        pr: {url: null}, hints: {open_decisions: [], pending_decision: false, last_event_text: "working: raw needs-decision jargon"}},
       {id: "stuck-task", kind: "ship", project: "sample",
        current_state: {state: "blocked", source: "status-log", detail: ""}, pr: {url: null},
        hints: {open_decisions: [], pending_decision: false, last_event_text: ""}},
       {id: "deciding-task", kind: "scout", project: "sample",
        current_state: {state: "working", source: "pane", detail: ""}, pr: {url: null},
        hints: {open_decisions: [{key: "k", verb: "needs-decision"}], pending_decision: true, last_event_text: "needs-decision [key=k]: x"}},
       {id: "green-task", kind: "ship", project: "sample",
        current_state: {state: "done", source: "run-step", detail: "checks green"},
        pr: {url: "https://github.com/sample/repo/pull/9"}, hints: {open_decisions: []}},
       {id: "gone-task", kind: "ship", project: "sample",
        current_state: {state: "dead", source: "pane", detail: ""}, pr: {url: null}, hints: {}},
       {id: "parked-task", kind: "ship", project: "sample",
        current_state: {state: "parked", source: "run-step", detail: ""}, pr: {url: null}, hints: {}},
       {id: "mate", kind: "secondmate", project: "/homes/mate",
        current_state: {state: "unknown", source: "none", detail: ""}, pr: {url: null}, hints: {}}
     ],
     secondmate_current: {records: [
       {id: "mate", decisions_open: [
         {id: "mate-call", key: "mate-call", verb: "captain-hold", summary: "Mate question", reason: "Pick one", hold_age_days: 2},
         {id: "mate-worker", key: "k", verb: "needs-decision", summary: "worker decision", reason: null}]}]}}
  ' > "$1"
}

test_model_renders_a_fixture_snapshot() {
  local home snap model model2 snap2
  home=$(make_home render)
  snap="$TMP_ROOT/fixture-snapshot.json"
  write_fixture_snapshot "$snap"
  cat > "$home/data/board-notes.json" <<'EOF'
[{"kind": "fyi", "text": "A release is pending", "link": "https://example.com/r"},
 {"kind": "you", "text": "Renew the certificate", "detail": "Expires Friday", "link": "javascript:alert(1)"},
 {"kind": "fyi", "text": "Unsafe link dropped", "link": "javascript:alert(1)"},
 {"text": 7}]
EOF
  model=$(in_home "$home" "$BOARD" model --snapshot-file "$snap") || fail "model failed on a fixture snapshot"
  printf '%s' "$model" | jq -e '
    .schema == "fm-board.v1" and .lead == "Bro" and .product == "shuvbro"
    and ([.waiting_on_you[] | .id // .title] == ["call-live", "work-gated", "Renew the certificate", "mate-call", "call-aged"])
  ' >/dev/null || fail "waiting on you is not the live holds, notes, second mate holds, then older holds: $model"
  printf '%s' "$model" | jq -e '
    (.waiting_on_you | map({key: (.id // .title), value: .}) | from_entries) as $w
    | $w["call-live"].choices == [{id: "yes", label: "Yes"}, {id: "no", label: "No"}]
      and $w["call-live"].answer_mode == "done"
      and $w["call-live"].links == ["https://github.com/sample/repo/pull/13"]
      and ($w["call-live"].card | test("^[0-9a-f]{64}$"))
      and $w["work-gated"].choices == [{id: "opt-1", label: "Staged"}, {id: "opt-2", label: "All at once"}]
      and $w["work-gated"].answer_mode == "release"
      and $w["call-aged"].aged == true and $w["call-aged"].answerable == true
      and $w["Renew the certificate"].answerable == false and $w["Renew the certificate"].links == []
      and ($w["Renew the certificate"] | has("card") | not)
      and $w["mate-call"].answerable == false and $w["mate-call"].from == "mate"
  ' >/dev/null || fail "waiting cards carry the wrong choices, close mode, links, or answerability: $model"
  printf '%s' "$model" | jq -e '
    (.in_flight | map({key: .id, value: .}) | from_entries) as $f
    | $f["running-task"].label == "In automated review" and $f["running-task"].project == "sample"
      and $f["running-task"].note == "working: raw needs-decision jargon"
      and $f["stuck-task"].label == "Stuck, Bro is on it"
      and $f["deciding-task"].label == "Decision pending, Bro is on it" and $f["deciding-task"].kind == "scout"
      and $f["green-task"].label == "PR ready, checks passing" and $f["green-task"].pr == "https://github.com/sample/repo/pull/9"
      and $f["gone-task"].label == "Stopped responding"
      and $f["parked-task"].label == "Review step needs a call, Bro is on it"
      and $f["mate"].kind == "second mate" and $f["mate"].label == "Status unknown"
      and ([.in_flight[].label] | all(test("needs-decision|blocked|parked|paused|^done$") | not))
  ' >/dev/null || fail "in-flight labels are not plain-language outcomes: $model"
  printf '%s' "$model" | jq -e '
    (.queued | map({key: .id, value: .note}) | from_entries) == {
      "call-dated": "back to you on 2026-08-01",
      "call-blocked": "back to you after migration-task",
      "plain-queued": "after Ship the widget"}
    and (.done | length) == 12 and .done[0].pr == "https://github.com/sample/repo/pull/100"
    and .fyi == [{text: "A release is pending", detail: null, link: "https://example.com/r"},
                 {text: "Unsafe link dropped", detail: null, link: null}]
    and .errors == ["1 heads-up note(s) were skipped because they are not in the expected shape."]
  ' >/dev/null || fail "queued, done, heads-up, or note errors are wrong: $model"

  model2=$(in_home "$home" "$BOARD" model --snapshot-file "$snap")
  [ "$(printf '%s' "$model" | jq -c '[.waiting_on_you[].card]')" = "$(printf '%s' "$model2" | jq -c '[.waiting_on_you[].card]')" ] \
    || fail "card digests are not stable across builds"
  snap2="$TMP_ROOT/fixture-snapshot-reasked.json"
  jq '(.backlog.records[] | select(.id == "call-live") | .hold_reason) = "Close only PR 13?"' "$snap" > "$snap2"
  model2=$(in_home "$home" "$BOARD" model --snapshot-file "$snap2")
  [ "$(printf '%s' "$model" | jq -r '.waiting_on_you[0].card')" != "$(printf '%s' "$model2" | jq -r '.waiting_on_you[0].card')" ] \
    || fail "a re-asked question kept its old card digest"
  [ "$(printf '%s' "$model" | jq -r '.waiting_on_you[1].card')" = "$(printf '%s' "$model2" | jq -r '.waiting_on_you[1].card')" ] \
    || fail "re-asking one question changed another card's digest"

  printf '{"broken"' > "$home/data/board-notes.json"
  model=$(in_home "$home" "$BOARD" model --snapshot-file "$snap") || fail "a broken notes file stopped the board"
  printf '%s' "$model" | jq -e '.errors == ["The heads-up notes file data/board-notes.json is not valid JSON."] and .fyi == []' \
    >/dev/null || fail "a broken notes file was not reported on the board: $model"
  pass "the board view renders a fixture snapshot and notes into plain-language sections and pinned cards"
}

test_page_and_data_are_guarded() {
  local home out i
  home=$(make_home serve)
  hold "$home" call-a --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes"
  start_board "$home"

  out=$(http GET / '{}')
  [ "$(status_of "$out")" = 200 ] || fail "the page did not load: $out"
  headers_of "$out" | jq -e '
    (."content-security-policy" | test("script-src .nonce-") and test("frame-ancestors .none."))
    and ."x-frame-options" == "DENY" and ."cache-control" == "no-store"
  ' >/dev/null || fail "the page lacks its security headers: $(headers_of "$out")"
  out=$(http GET /board.json '{}')
  body_of "$out" | jq -e '.schema == "fm-board.v1" and (.instance | test("^[0-9a-f]{16}$"))
    and .waiting_on_you[0].id == "call-a" and .refresh_seconds == 2 and (has("token") | not)' >/dev/null \
    || fail "board data is wrong or leaks the token: $out"
  in_home "$home" "$BOARD" status | grep -F "serving: http://127.0.0.1:$BOARD_PORT/" >/dev/null \
    || fail "status did not report the running board"

  expect_refusal "$(http GET /board.json "{\"Host\": \"evil.example:$BOARD_PORT\"}")" 403 bad_host \
    "a rebinding host name was served"
  expect_refusal "$(http GET / '{"X-Forwarded-Host": "evil.example"}')" 403 bad_host \
    "a foreign forwarded host was served"
  expect_refusal "$(http GET /board.json '{"Tailscale-Funnel-Request": "?1"}')" 403 funnel_refused \
    "a public Funnel request was served"
  expect_refusal "$(http GET /nope '{}')" 404 not_found "an unknown path was served"
  expect_refusal "$(http GET /answer '{}')" 405 bad_method "the answer endpoint accepted GET"
  expect_refusal "$(http DELETE /board.json '{}')" 405 bad_method "board data accepted DELETE"
  if (cd "$home" && PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_BOARD_PORT=0 \
    "$BOARD" serve > "$home/second.log" 2>&1); then
    fail "a second board started for a home that already serves one"
  fi
  grep -F "already serving" "$home/second.log" >/dev/null || fail "the duplicate start did not say why: $(cat "$home/second.log")"
  stop_boards
  i=0
  while [ -e "$home/state/board/serve.json" ]; do
    i=$((i + 1))
    [ "$i" -le 100 ] || fail "a stopped board left its record behind"
    sleep 0.1
  done
  if in_home "$home" "$BOARD" status > "$home/status.out"; then
    fail "status reported a stopped board as serving"
  fi
  grep -F "not serving" "$home/status.out" >/dev/null || fail "status did not say the board is not serving"
  pass "the page and data carry security headers, answer only known hosts, and keep one board per home"
}

test_answer_requests_are_validated() {
  local home out long origin_headers before
  home=$(make_home validate)
  hold "$home" call-v --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes"
  hold "$home" call-w --title "Rename it?" --reason "Rename foo to bar? Recommend no"
  start_board "$home"
  before=$(cat "$home/data/backlog.md")
  origin_headers=$(jq -cn --arg o "$(local_origin)" '{"Content-Type": "application/json", Origin: $o}')

  expect_refusal "$(post_answer "$(jq -cn --arg t "$BOARD_TOKEN" --arg c "$(card_of call-v)" \
    '{token: $t, task: "no-such-task", card: $c, choice: "yes"}')")" 400 unknown_task "an unknown id was accepted"
  expect_refusal "$(post_answer "$(jq -cn --arg t "$BOARD_TOKEN" --arg c "$(card_of call-v)" \
    '{token: $t, task: "sample-plain", card: $c, choice: "yes"}')")" 409 not_waiting "a task not waiting on the captain was answered"
  expect_refusal "$(post_answer "$(answer_body call-v maybe)")" 400 bad_choice "an unknown answer was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v opt-2)")" 400 bad_choice "an undeclared option was accepted"
  long=$(printf 'x%.0s' $(seq 1 501))
  expect_refusal "$(post_answer "$(answer_body call-v reply "$(jq -cn --arg t "$long" '{text: $t}')")")" 400 bad_text \
    "an oversized reply was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v reply '{"text": "   "}')")" 400 bad_text "an empty reply was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v reply '{"text": "reconcile"}')")" 400 reserved \
    "the reserved reconcile value was accepted as a reply"
  expect_refusal "$(post_answer "$(answer_body call-v yes '{"text": "sneaky"}')")" 400 bad_request "text rode along on a button answer"
  expect_refusal "$(post_answer "$(answer_body call-v later "$(jq -cn --arg d "$(utc_day 0)" '{until: $d}')")")" 400 bad_date \
    "a deferral to today was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v later "$(jq -cn --arg d "$(utc_day 400)" '{until: $d}')")")" 400 bad_date \
    "a deferral more than a year out was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes | jq -c 'del(.token)')")" 403 bad_token "a missing token was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes | jq -c '.token = ("0" * 64)')")" 403 bad_token "a wrong token was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes | jq -c '.token = "short"')")" 403 bad_token "a short token was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes)" '{"Content-Type": "application/json", "Origin": "https://evil.example"}')" \
    403 bad_origin "a cross-site origin was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes)" '{"Content-Type": "application/json"}')" \
    403 bad_origin "a request without an origin was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes)" "$(printf '%s' "$origin_headers" | jq -c '. + {"Sec-Fetch-Site": "cross-site"}')")" \
    403 bad_origin "a cross-site fetch was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes)" "$(jq -cn --arg o "$(local_origin)" '{"Content-Type": "text/plain", Origin: $o}')")" \
    415 bad_request "a non-JSON body was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes | jq -c '. + {extra: 1}')")" 400 bad_request "an unknown field was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes | jq -c --arg pad "$(printf 'y%.0s' $(seq 1 9000))" '. + {pad: $pad}')")" \
    413 bad_request "an oversized body was accepted"
  expect_refusal "$(post_answer "$(answer_body call-v yes | jq -c '.card = ("a" * 64)')")" 409 stale_card \
    "an answer to a superseded question was accepted"

  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "a refused request changed the backlog"
  [ "$(inbox_notes "$home")" = 0 ] || fail "a refused request woke the lead"
  [ ! -s "$home/state/.wake-queue" ] || fail "a refused request queued a wake: $(cat "$home/state/.wake-queue")"
  pass "the answer endpoint refuses unknown, non-held, malformed, oversized, cross-origin, and tokenless requests untouched"
}

test_tailscale_login_allowlist() {
  local home out ts_get
  home=$(make_home logins)
  printf '# the captain only\ncaptain@example.com\n' > "$home/config/board-logins"
  printf 'board.example.ts.net\n' > "$home/config/board-hosts"
  hold "$home" call-l --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes"
  start_board "$home"
  ts_get='{"Host": "board.example.ts.net", "X-Forwarded-For": "100.64.0.9", "X-Forwarded-Host": "board.example.ts.net"}'

  expect_refusal "$(http GET /board.json "$(printf '%s' "$ts_get" | jq -c '. + {"Tailscale-User-Login": "other@example.com"}')")" \
    403 login_refused "another tailnet login could read the board"
  expect_refusal "$(http GET /board.json "$ts_get")" 403 login_refused "a proxied request without a login could read the board"
  out=$(http GET /board.json "$(printf '%s' "$ts_get" | jq -c '. + {"Tailscale-User-Login": "Captain@Example.com"}')")
  [ "$(status_of "$out")" = 200 ] || fail "the allowlisted login could not read the board: $out"
  [ "$(status_of "$(http GET /board.json '{}')")" = 200 ] || fail "a direct loopback request was refused"
  expect_refusal "$(http GET /board.json '{"X-Forwarded-For": "100.64.0.9"}')" 403 login_refused \
    "a proxied loopback request without a login was served"

  expect_refusal "$(post_answer "$(answer_body call-l yes)" "$(jq -cn '{"Content-Type": "application/json",
      Host: "board.example.ts.net", Origin: "https://board.example.ts.net", "X-Forwarded-For": "100.64.0.9",
      "X-Forwarded-Host": "board.example.ts.net", "Tailscale-User-Login": "other@example.com"}')")" \
    403 login_refused "a disallowed login could answer"
  task_show "$home" call-l | grep -F "held: yes" >/dev/null || fail "a refused login changed the hold"

  out=$(post_answer "$(answer_body call-l yes)" "$(jq -cn '{"Content-Type": "application/json",
      Host: "board.example.ts.net", Origin: "https://board.example.ts.net", "X-Forwarded-For": "100.64.0.9",
      "X-Forwarded-Host": "board.example.ts.net", "Tailscale-User-Login": "captain@example.com"}')")
  [ "$(status_of "$out")" = 200 ] || fail "the allowlisted login could not answer: $out"
  task_show "$home" call-l | grep -F "through live board, signed in as captain@example.com" >/dev/null \
    || fail "the recorded answer does not name the signed-in login: $(task_show "$home" call-l)"
  pass "a configured login allowlist admits only the captain's Tailscale login and direct local requests"
}

test_answers_land_through_the_intake() {
  local home out show until notes rows data id text i
  home=$(make_home answers)
  hold "$home" call-yes --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes"
  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  hold "$home" sample-plain --reason "Land the plain work now? Recommend yes"
  hold "$home" call-later --title "Rename it?" --reason "Rename foo to bar? Recommend no" \
    --option "Rename" --option "Keep foo"
  hold "$home" call-reply --title "Pick a database" --reason "Postgres or SQLite? Recommend SQLite"
  hold "$home" call-option --title "Pick a rollout" --reason "Staged or all at once?" \
    --option "Staged" --option "All at once"
  start_board "$home"
  until=$(utc_day 7)

  out=$(post_answer "$(answer_body call-yes yes)")
  [ "$(status_of "$out")" = 200 ] && [ "$(body_of "$out" | jq -r '.outcome')" = closed ] \
    || fail "a yes on a question was not recorded and closed: $out"
  show=$(task_show "$home" call-yes)
  printf '%s\n' "$show" | grep -F "state: done" >/dev/null || fail "a yes left the question open: $show"
  for text in "Captain answered this call through live board." "Answer: yes" \
    "Answer as shown to the captain: Yes - in reply to: Close duplicate PR 13? Recommend yes"; do
    printf '%s\n' "$show" | grep -F "$text" >/dev/null || fail "the recorded yes lacks [$text]: $show"
  done

  out=$(post_answer "$(answer_body sample-ship no)")
  [ "$(body_of "$out" | jq -r '.outcome')" = recorded ] || fail "a no on held work was not recorded: $out"
  show=$(task_show "$home" sample-ship)
  printf '%s\n' "$show" | grep -F "state: queued" >/dev/null || fail "an answer marked held work complete: $show"
  printf '%s\n' "$show" | grep -F "held: yes" >/dev/null || fail "a no released held work: $show"
  printf '%s\n' "$show" | grep -F "Answer: no" >/dev/null || fail "the recorded no is missing: $show"
  printf '%s\n' "$show" | grep -F "Captain answer recorded:" >/dev/null || fail "the no was not recorded on the task: $show"
  local_merge_refused "$home" sample-ship

  out=$(post_answer "$(answer_body sample-plain reply '{"text": "Not yet, wait for the docs"}')")
  [ "$(body_of "$out" | jq -r '.outcome')" = recorded ] || fail "a typed reply on held work was not recorded: $out"
  show=$(task_show "$home" sample-plain)
  printf '%s\n' "$show" | grep -F "held: yes" >/dev/null || fail "a typed reply released held work: $show"
  printf '%s\n' "$show" | grep -F "Answer: Not yet, wait for the docs" >/dev/null || fail "the typed reply on held work is missing: $show"
  local_merge_refused "$home" sample-plain

  data=$(board_data)
  printf '%s' "$data" | jq -e '
    ([.waiting_on_you[] | select(.answerable) | .id] | index("sample-ship") == null and index("sample-plain") == null)
    and ([.with_lead[] | {id, answer}] == [{id: "sample-ship", answer: "no"}, {id: "sample-plain", answer: "Not yet, wait for the docs"}])
    and all(.with_lead[]; (.answered_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and (has("card") | not))
  ' >/dev/null || fail "a no and a reply on held work did not move it from Waiting on you to Answered: $data"
  out=$(post_answer "$(jq -cn --arg t "$BOARD_TOKEN" '{token: $t, task: "sample-ship", card: ("c" * 64), choice: "yes"}')")
  expect_refusal "$out" 409 not_waiting "an answered held item could still be answered from the board"

  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  i=0
  until [ -n "$(card_of sample-ship)" ]; do
    i=$((i + 1))
    [ "$i" -le 100 ] || fail "a same-reason re-hold did not return answered work to Waiting on you: $(board_data)"
    sleep 0.1
  done
  out=$(post_answer "$(answer_body sample-ship no)")
  [ "$(body_of "$out" | jq -r '.outcome')" = recorded ] || fail "a repeated no on re-asked work was not recorded: $out"
  board_data | jq -e 'any(.with_lead[]; .id == "sample-ship" and .answer == "no")
    and all(.waiting_on_you[]; .id != "sample-ship")' >/dev/null \
    || fail "the same no to a re-asked question left it waiting on the captain: $(board_data)"

  hold "$home" sample-ship --reason "Merge PR 5 after the docs land? Recommend yes"
  i=0
  until [ -n "$(card_of sample-ship)" ]; do
    i=$((i + 1))
    [ "$i" -le 100 ] || fail "a re-hold did not return answered work to Waiting on you: $(board_data)"
    sleep 0.1
  done
  board_data | jq -e 'all(.with_lead[]; .id != "sample-ship")' >/dev/null \
    || fail "re-held work is still listed as answered: $(board_data)"

  out=$(post_answer "$(answer_body sample-ship yes)")
  [ "$(body_of "$out" | jq -r '.outcome')" = released ] || fail "a yes on held work was not released: $out"
  show=$(task_show "$home" sample-ship)
  printf '%s\n' "$show" | grep -F "state: queued" >/dev/null || fail "a yes marked held work complete: $show"
  printf '%s\n' "$show" | grep -F "held: no" >/dev/null || fail "a yes left held work held: $show"

  out=$(post_answer "$(answer_body call-later later "$(jq -cn --arg d "$until" '{until: $d}')")")
  [ "$(body_of "$out" | jq -r '.outcome')" = deferred ] || fail "later was not recorded as a deferral: $out"
  show=$(task_show "$home" call-later)
  printf '%s\n' "$show" | grep -F "hold_until: $until" >/dev/null || fail "later did not set the return date: $show"
  printf '%s\n' "$show" | grep -F "held: yes" >/dev/null || fail "later closed or released the question: $show"
  printf '%s\n' "$show" | grep -F "Captain hold options: Rename | Keep foo" >/dev/null || fail "later dropped the declared options: $show"
  printf '%s\n' "$show" | grep -F "Resolution recorded" >/dev/null && fail "later recorded a resolution: $show"
  printf '%s\n' "$show" | grep -F "Answer: later, until $until" >/dev/null || fail "later was not recorded on the task: $show"
  board_data | jq -e 'all(.waiting_on_you[], .with_lead[]; .id != "call-later")' >/dev/null \
    || fail "a deferred question is still waiting on the captain or listed as answered: $(board_data)"
  in_home "$home" env FM_SNAPSHOT_NOW="${until}T12:00:00Z" "$BOARD" model \
    | jq -e 'any(.waiting_on_you[]; .id == "call-later" and .answerable) and all(.with_lead[]; .id != "call-later")' >/dev/null \
    || fail "a deferred question did not return to Waiting on you on its date"

  out=$(post_answer "$(answer_body call-reply reply '{"text": "SQLite for now,\n\tmove later"}')")
  [ "$(body_of "$out" | jq -r '.outcome')" = closed ] || fail "a typed reply was not recorded: $out"
  show=$(task_show "$home" call-reply)
  printf '%s\n' "$show" | grep -F "Answer: SQLite for now, move later" >/dev/null || fail "the typed reply was not recorded verbatim on one line: $show"
  printf '%s\n' "$show" | grep -F "Answer as shown to the captain: Typed reply - in reply to: Postgres or SQLite? Recommend SQLite" \
    >/dev/null || fail "the typed reply does not record what it answered: $show"

  out=$(post_answer "$(answer_body call-option opt-2)")
  [ "$(body_of "$out" | jq -r '.outcome')" = closed ] || fail "a declared option was not recorded: $out"
  task_show "$home" call-option | grep -F "Answer: All at once" >/dev/null || fail "the declared option label was not recorded"

  notes=$(inbox_notes "$home")
  [ "$notes" = 8 ] || fail "expected one captain inbox note per answer, found $notes"
  for id in call-yes sample-ship sample-plain call-later call-reply call-option; do
    grep -l -F "Live board answer for $id:" "$home"/state/inbox/*.note >/dev/null \
      || fail "no inbox note announced the answer for $id"
  done
  grep -h -F "deferred until $until" "$home"/state/inbox/*.note >/dev/null || fail "the deferral note lacks its date"
  rows=$(awk -F '\t' '$3 == "check" && $4 ~ /^inbox:/' "$home/state/.wake-queue" | wc -l | tr -d ' ')
  [ "$rows" = 8 ] || fail "expected eight check wakes for the lead, found $rows: $(cat "$home/state/.wake-queue")"

  data=$(board_data)
  printf '%s' "$data" | jq -e --arg d "$until" '
    [.waiting_on_you[] | select(.answerable) | .id] == []
    and [.with_lead[].id] == ["sample-plain"]
    and any(.queued[]; .id == "call-later" and .note == "back to you on \($d)")
  ' >/dev/null || fail "answered items did not leave Waiting on you after the refresh: $data"
  printf '%s' "$data" | jq -e '[.done[].id] | all(. != "call-yes" and . != "call-reply" and . != "call-option")' >/dev/null \
    || fail "an answered captain question is shown as Recently done: $data"
  out=$(post_answer "$(jq -cn --arg t "$BOARD_TOKEN" '{token: $t, task: "call-yes", card: ("b" * 64), choice: "yes"}')")
  expect_refusal "$out" 409 not_waiting "an already answered question was answered again"
  [ "$(inbox_notes "$home")" = 8 ] || fail "a refused repeat answer woke the lead"
  pass "yes, no, later, typed replies, and declared options land through the intake with board provenance and one wake each, and yes releases held work"
}

test_same_second_answer_still_moves_to_answered() {
  local home now model
  home=$(make_home same-second)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  FM_CAPTAIN_HOLD_NOW=$now hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  printf 'sample-ship\tno\tNo - in reply to: Merge PR 5 now? Recommend yes\trecord\n' \
    | FM_CAPTAIN_HOLD_NOW=$now in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "live board" >/dev/null \
    || fail "a same-second no was not recorded"
  task_show "$home" sample-ship | grep -F "held: yes" >/dev/null || fail "a same-second no released the work"
  model=$(in_home "$home" "$BOARD" model) || fail "model failed after a same-second answer"
  printf '%s' "$model" | jq -e '[.with_lead[] | {id, answer}] == [{id: "sample-ship", answer: "no"}]
    and all(.waiting_on_you[]; .id != "sample-ship")' >/dev/null \
    || fail "a no recorded in the same second as the hold left it waiting on the captain: $model"
  pass "a no recorded in the same second as the hold still moves the item to Answered"
}

# Re-asking an answered call takes more than one backlog write. A wrapper around
# tasks-axi reads the board after every write, so each state a concurrent
# refresh could capture is checked: the old question must never be offered
# again, or a click on it is refused once the re-ask lands.
test_reasking_an_answered_call_never_offers_the_old_question() {
  local home real seen final
  home=$(make_home re-ask)
  real=$(command -v tasks-axi)
  seen="$home/seen-cards"
  : > "$seen"
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
"$real" "\$@" || exit \$?
case "\${1:-}" in
  hold|update)
    "$BOARD" model | jq -r '.waiting_on_you[] | select(.answerable and .id == "sample-ship") | "\(.card) \(.reason)"' >> "$seen"
    ;;
esac
SH
  chmod +x "$home/fakebin/tasks-axi"
  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  printf 'sample-ship\tno\tNo - in reply to: Merge PR 5 now? Recommend yes\trecord\n' \
    | in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "live board" >/dev/null \
    || fail "the first no was not recorded"
  : > "$seen"
  hold "$home" sample-ship --reason "Merge PR 5 after the docs land? Recommend yes"
  final=$(in_home "$home" "$BOARD" model | jq -r '.waiting_on_you[] | select(.answerable and .id == "sample-ship") | "\(.card) \(.reason)"')
  [ -n "$final" ] && [ "${final#* }" = "Merge PR 5 after the docs land? Recommend yes" ] \
    || fail "the re-asked call is not waiting on the captain: $final"
  [ -s "$seen" ] || fail "no intermediate board read was observed during the re-ask"
  if grep -v -x -F "$final" "$seen" | grep -q .; then
    fail "while the call was re-asked the board offered a question that was not the re-asked one: $(grep -v -x -F "$final" "$seen" | sort -u)"
  fi
  pass "re-asking an answered call never offers the already-answered question while the re-ask is written"
}

test_later_that_cannot_defer_is_still_recorded() {
  local home real out show until
  home=$(make_home later-fails)
  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = hold ]; then
  for arg in "\$@"; do
    [ "\$arg" != --until ] || { echo "tasks-axi: the date gate is unavailable" >&2; exit 1; }
  done
fi
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  start_board "$home"
  until=$(utc_day 7)

  out=$(post_answer "$(answer_body sample-ship later "$(jq -cn --arg d "$until" '{until: $d}')")")
  [ "$(status_of "$out")" = 200 ] || fail "a recorded Later whose deferral failed was reported as a failure: $out"
  body_of "$out" | jq -e '.ok == true and .outcome == "not_deferred" and (.message | test("^Recorded, but it could not be moved"))' \
    >/dev/null || fail "a recorded Later whose deferral failed has no distinct, consistent outcome: $out"
  show=$(task_show "$home" sample-ship)
  printf '%s\n' "$show" | grep -F "held: yes" >/dev/null || fail "a failed deferral released the work: $show"
  printf '%s\n' "$show" | grep -F "Answer: later, until $until" >/dev/null || fail "the Later answer was not recorded: $show"
  printf '%s\n' "$show" | grep -F "hold_until: $until" >/dev/null && fail "the failed deferral still set the date: $show"
  board_data | jq -e 'any(.with_lead[]; .id == "sample-ship" and .answer == "later, until \($d)")
    and all(.waiting_on_you[]; .id != "sample-ship")' --arg d "$until" >/dev/null \
    || fail "a recorded Later whose deferral failed is not listed as answered: $(board_data)"
  [ "$(inbox_notes "$home")" = 1 ] || fail "a recorded Later whose deferral failed did not wake the lead"
  grep -h -F "deferring until $until failed" "$home"/state/inbox/*.note >/dev/null \
    || fail "the lead's note does not say the deferral failed: $(cat "$home"/state/inbox/*.note)"
  pass "a Later whose deferral fails is still recorded, reported as not deferred, and wakes the lead"
}

test_failed_later_repair_is_not_success_or_answerable() {
  local home real out until
  home=$(make_home later-repair-fails)
  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = update ] && [ "\${2:-}" = sample-ship ]; then
  count=0
  [ ! -f "$home/update-count" ] || count=\$(cat "$home/update-count")
  count=\$((count + 1))
  echo "\$count" > "$home/update-count"
  [ "\$count" != 2 ] || { echo "tasks-axi: repair write unavailable" >&2; exit 1; }
fi
if [ "\${1:-}" = hold ]; then
  for arg in "\$@"; do
    [ "\$arg" != --until ] || { echo "tasks-axi: date gate unavailable" >&2; exit 1; }
  done
fi
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  start_board "$home"
  until=$(utc_day 7)
  out=$(post_answer "$(answer_body sample-ship later "$(jq -cn --arg d "$until" '{until: $d}')")")
  expect_refusal "$out" 500 repair_failed "a failed Later repair reported success"
  [ "$(cat "$home/update-count")" = 2 ] || fail "the second update was not exercised"
  board_data | jq -e 'any(.with_lead[]; .id == "sample-ship")
    and all(.waiting_on_you[]; .id != "sample-ship")' >/dev/null \
    || fail "a failed Later repair offered Yes/No again: $(board_data)"
  [ "$(inbox_notes "$home")" = 1 ] || fail "a failed Later repair did not wake the lead about the recorded answer"
  grep -h -F "the follow-up record did not land, so the outcome is uncertain" "$home"/state/inbox/*.note >/dev/null \
    || fail "the lead's note does not say the failed repair left the outcome uncertain: $(cat "$home"/state/inbox/*.note)"
  local_merge_refused "$home" sample-ship
  pass "a failed Later repair reports failure and wakes the lead without restoring answer buttons or releasing work"
}

test_declared_option_keeps_held_work_held() {
  local home out show
  home=$(make_home held-option)
  hold "$home" sample-ship --reason "Which rollout? Recommend staged" --option "Staged" --option "Not yet"
  start_board "$home"
  board_data | jq -e 'any(.waiting_on_you[]; .id == "sample-ship" and .answer_mode == "release"
    and .choices == [{id: "opt-1", label: "Staged"}, {id: "opt-2", label: "Not yet"}])' >/dev/null \
    || fail "held work did not offer its declared options: $(board_data)"
  out=$(post_answer "$(answer_body sample-ship opt-2)")
  [ "$(status_of "$out")" = 200 ] && [ "$(body_of "$out" | jq -r '.outcome')" = recorded ] \
    || fail "a declared option on held work was not recorded without releasing it: $out"
  show=$(task_show "$home" sample-ship)
  printf '%s\n' "$show" | grep -F "held: yes" >/dev/null || fail "a declared option released held work: $show"
  printf '%s\n' "$show" | grep -F "Answer: Not yet" >/dev/null || fail "the chosen option was not recorded: $show"
  printf '%s\n' "$show" | grep -F "Captain answer recorded:" >/dev/null || fail "the option was not recorded on the task: $show"
  local_merge_refused "$home" sample-ship
  board_data | jq -e 'any(.with_lead[]; .id == "sample-ship" and .answer == "Not yet")
    and all(.waiting_on_you[]; .id != "sample-ship")' >/dev/null \
    || fail "a declared option on held work is not listed as answered with the lead: $(board_data)"
  [ "$(inbox_notes "$home")" = 1 ] || fail "a declared option on held work did not wake the lead"
  grep -h -F "the held work stays held until you act on this answer" "$home"/state/inbox/*.note >/dev/null \
    || fail "the lead's note does not say the work stays held: $(cat "$home"/state/inbox/*.note)"
  pass "a declared option on held work is recorded for the lead and never releases it"
}

# A re-ask that lands after the board read the card but before the answer is
# written must never receive the old click. The tasks-axi wrapper starts the
# re-ask at the first call after that read and gives it time to finish.
test_reask_during_an_answer_never_takes_the_old_click() {
  local home real out i=0
  home=$(make_home answer-race)
  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = --version ] && rm "$home/race-armed" 2>/dev/null; then
  ( cd "$home" && env -u FM_CAPTAIN_HOLD_LOCKED_BY "$ROOT/bin/fm-captain-hold.sh" hold sample-ship \
      --reason "Merge PR 5 after the docs land? Recommend yes"; touch "$home/race-done" ) >/dev/null 2>&1 &
  for _ in \$(seq 1 30); do [ ! -e "$home/race-done" ] || break; sleep 0.1; done
fi
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  start_board "$home"
  out=$(answer_body sample-ship yes)
  touch "$home/race-armed"
  out=$(post_answer "$out")
  [ ! -e "$home/race-armed" ] || fail "the re-ask was never started during the answer"
  while [ ! -e "$home/race-done" ]; do
    i=$((i + 1))
    [ "$i" -le 200 ] || fail "the re-ask never finished"
    sleep 0.1
  done
  case "$(status_of "$out"):$(body_of "$out" | jq -r '.outcome // .code')" in
    200:released|409:stale_card) : ;;
    *) fail "an answer racing a re-ask ended unexpectedly: $out" ;;
  esac
  task_show "$home" sample-ship | grep -F "held: yes" >/dev/null \
    || fail "the old click released the re-asked question: $(task_show "$home" sample-ship)"
  i=0
  until board_data | jq -e 'any(.waiting_on_you[]; .id == "sample-ship" and .answerable
      and .reason == "Merge PR 5 after the docs land? Recommend yes")' >/dev/null; do
    i=$((i + 1))
    [ "$i" -le 100 ] || fail "the re-asked question is not waiting on the captain: $(board_data)"
    sleep 0.1
  done
  pass "a re-ask racing an answer is never answered by the old click"
}

test_board_without_logins_is_local_only() {
  local home out
  home=$(make_home local-only)
  printf 'board.example.ts.net\n' > "$home/config/board-hosts"
  if in_home "$home" env FM_BOARD_PORT=0 "$BOARD" serve > "$home/hosts.log" 2>&1; then
    fail "the board started for extra host names without a login allowlist"
  fi
  grep -F "board-logins is empty" "$home/hosts.log" >/dev/null \
    || fail "the refused start did not name the missing login allowlist: $(cat "$home/hosts.log")"
  [ ! -e "$home/state/board/serve.json" ] || fail "a refused start left a serve record"
  rm "$home/config/board-hosts"
  start_board "$home"
  out=$(http GET /board.json '{}')
  [ "$(status_of "$out")" = 200 ] || fail "a direct loopback request was refused without logins: $out"
  expect_refusal "$(http GET /board.json '{"X-Forwarded-For": "100.64.0.9"}')" 403 local_only \
    "a proxied request was served without a login allowlist"
  expect_refusal "$(http GET / '{"X-Forwarded-Host": "127.0.0.1"}')" 403 local_only \
    "a forwarded loopback request was served without a login allowlist"
  expect_refusal "$(http GET /board.json '{"Tailscale-User-Login": "anyone@example.com"}')" 403 local_only \
    "a Tailscale login was trusted without a login allowlist"
  pass "without a login allowlist the board refuses extra host names and every proxied request"
}

test_page_staleness_ignores_the_phone_clock() {
  local home
  home=$(make_home page-clock)
  hold "$home" sample-ship --reason "Which rollout?" --option "Staged" --option "Not yet"
  hold "$home" call-yes --title "Close it?" --reason "Close it?"
  start_board "$home"
  board_data | jq -e '.age_seconds | type == "number" and . >= 0' >/dev/null \
    || fail "board data does not carry its server-measured age: $(board_data)"
  node - "$BOARD_PORT" <<'JS' || fail "the page misreported staleness or styled options like Yes"
const assert = require('node:assert/strict');
const vm = require('node:vm');
const origin = `http://127.0.0.1:${process.argv[2]}`;
(async () => {
  const page = await (await fetch(origin)).text();
  const nodes = new Map();
  const node = (id) => {
    if (!nodes.has(id)) nodes.set(id, { innerHTML: '', textContent: '', className: '', dataset: {} });
    return nodes.get(id);
  };
  let skew = 10 * 60000, elapsed = 0, offline = false;
  class PhoneDate extends Date { static now() { return Date.now() + skew + elapsed; } }
  const context = vm.createContext({
    console, Date: PhoneDate, Map, Set, CSS: { escape: (s) => s }, setInterval: () => {},
    location: { reload() { throw new Error('unexpected reload'); } },
    document: {
      getElementById: node, addEventListener() {}, activeElement: null,
      querySelector(selector) {
        const name = /meta\[name="([^"]+)"\]/.exec(selector)?.[1];
        return name ? { content: new RegExp(`name="${name}" content="([^"]+)"`).exec(page)[1] } : null;
      },
    },
    fetch: async (path, options = {}) => {
      if (offline) throw new TypeError('network down');
      return fetch(new URL(path, origin), options);
    },
  });
  vm.runInContext(/<script[^>]*>([\s\S]*?)<\/script>/.exec(page)[1], context);
  const updated = node('updated');
  await vm.runInContext('refresh()', context);
  assert.equal(updated.className, 'updated', 'a phone clock ten minutes fast marked a fresh board stale');
  assert.match(updated.textContent, /^updated \d+s ago$/);
  const you = node('you').innerHTML;
  assert.match(you, /class="primary"[^>]*data-choice="yes"/, 'Yes lost its emphasis');
  assert.match(you, /class=""[^>]*data-choice="opt-2"/, 'a declared option was styled like Yes');
  elapsed = 60000;
  vm.runInContext('tick()', context);
  assert.equal(updated.className, 'updated stale', 'a board with no update for a minute was not marked stale');
  assert.match(updated.textContent, /^Not updating - last update 1m ago$/);
  offline = true;
  await vm.runInContext('refresh()', context);
  assert.equal(updated.className, 'updated stale');
  assert.match(updated.textContent, /^Board offline - last update 1m ago$/);
  offline = false;
  skew = -10 * 60000;
  elapsed = 0;
  const fresh = await (await fetch(new URL('board.json', origin))).json();
  context.fetch = async () => ({ ok: true, json: async () => ({ ...fresh, age_seconds: 120 }) });
  await vm.runInContext('refresh()', context);
  assert.equal(updated.className, 'updated stale', 'a phone clock ten minutes slow hid a stuck board');
  assert.match(updated.textContent, /^Not updating - last update 2m ago$/);
})().catch((error) => { console.error(error); process.exitCode = 1; });
JS
  pass "the page judges staleness by the board's clock, reports offline, and styles declared options neutrally"
}

test_page_recovers_a_lost_committed_response() {
  local home
  home=$(make_home lost-response)
  hold "$home" sample-ship --reason "Merge PR 5 now? Recommend yes"
  hold "$home" lost-call --title "Close the question?" --reason "Close it?"
  start_board "$home"
  node - "$BOARD_PORT" <<'JS' || fail "the page did not recover the committed answer"
const assert = require('node:assert/strict');
const vm = require('node:vm');
const port = process.argv[2];
const origin = `http://127.0.0.1:${port}`;
(async () => {
  const page = await (await fetch(origin)).text();
  const nodes = new Map();
  const node = (id) => {
    if (!nodes.has(id)) nodes.set(id, { innerHTML: '', textContent: '', dataset: {} });
    return nodes.get(id);
  };
  let posts = 0, committedBody;
  let loseEveryResponse = false;
  const context = vm.createContext({
    console, Date, Map, Set, CSS: { escape: (s) => s }, setInterval: () => {},
    location: { reload() { throw new Error('unexpected reload'); } },
    document: {
      getElementById: node, addEventListener() {}, activeElement: null,
      querySelector(selector) {
        const name = /meta\[name="([^"]+)"\]/.exec(selector)?.[1];
        if (!name) return null;
        return { content: new RegExp(`name="${name}" content="([^"]+)"`).exec(page)[1] };
      },
    },
    fetch: async (path, options = {}) => {
      const headers = { ...options.headers, Origin: origin };
      const response = await fetch(new URL(path, origin), { ...options, headers });
      if (options.method === 'POST') {
        posts++;
        if (posts === 1 || loseEveryResponse) {
          committedBody = options.body;
          assert.equal(response.status, 200);
          assert.equal((await response.json()).outcome, loseEveryResponse ? 'closed' : 'released');
          // The real answer committed; discard its response on the phone side.
          throw new TypeError('connection lost after commit');
        }
        assert.equal(options.body, committedBody, 'recovery changed the original click');
      }
      return response;
    },
  });
  vm.runInContext(/<script[^>]*>([\s\S]*?)<\/script>/.exec(page)[1], context);
  await vm.runInContext('refresh()', context);
  await vm.runInContext('answer("sample-ship", "yes")', context);
  await vm.runInContext('refresh()', context);
  assert.equal(posts, 2, 'a lost response was not checked with the same request');
  assert.match(node('answered').innerHTML, /Recorded/);
  assert.doesNotMatch(node('answered').innerHTML + node('you').innerHTML, /Nothing was recorded|Not recorded:/);
  loseEveryResponse = true;
  await vm.runInContext('answer("lost-call", "yes")', context);
  await vm.runInContext('refresh()', context);
  assert.equal(posts, 4);
  assert.match(node('banner').innerHTML, /may have been recorded/);
  assert.match(node('banner').innerHTML, /data-act="refresh"/);
  assert.doesNotMatch(node('banner').innerHTML, /Nothing was recorded|Not recorded:/);
  // A known not_waiting response is not evidence that this click was unwritten.
  await vm.runInContext('render({instance: INSTANCE, waiting_on_you: [{id: "old", title: "Old question", answerable: true, card: "a".repeat(64), choices: []}]})', context);
  context.fetch = async () => ({ ok: true, json: async () => ({ ok: false, code: 'not_waiting', message: 'This is no longer waiting on you.' }) });
  await vm.runInContext('answer("old", "yes")', context);
  assert.match(node('banner').innerHTML, /no longer waiting/);
  assert.doesNotMatch(node('banner').innerHTML, /Not recorded:/);
})().catch((error) => { console.error(error); process.exitCode = 1; });
JS
  task_show "$home" sample-ship | grep -F 'held: no' >/dev/null || fail "the committed answer did not release work"
  [ "$(inbox_notes "$home")" = 2 ] || fail "a lost response recovery duplicated the inbox note"
  pass "the actual page recovers a response lost after a committed release without duplicating the answer"
}

test_answer_replay_survives_restart_without_reapplying() {
  local home body out card before i=0
  home=$(make_home replay)
  hold "$home" sample-ship --reason "Ship now?"
  start_board "$home"
  body=$(answer_body sample-ship yes)
  card=$(printf '%s' "$body" | jq -r .card)
  out=$(post_answer "$body")
  [ "$(body_of "$out" | jq -r .outcome)" = released ] || fail "initial answer did not land: $out"
  stop_boards
  # Wait for the old server to release its home record before restarting it.
  while [ -e "$home/state/board/serve.json" ]; do
    i=$((i + 1))
    [ "$i" -le 100 ] || fail "the server did not stop before replay"
    sleep 0.1
  done
  hold "$home" sample-ship --reason "Ship after docs?"
  start_board "$home"
  before=$(cat "$home/data/backlog.md")
  body=$(printf '%s' "$body" | jq -c --arg t "$BOARD_TOKEN" '.token = $t')
  out=$(post_answer "$body")
  [ "$(status_of "$out")" = 200 ] && [ "$(body_of "$out" | jq -r .outcome)" = released ] \
    || fail "an exact retry lost its committed result after restart: $out"
  expect_refusal "$(post_answer "$(printf '%s' "$body" | jq -c '.choice = "no"')")" 409 answer_conflict \
    "the same card accepted a different answer"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "a replay applied the old answer to a new hold"
  [ "$(inbox_notes "$home")" = 1 ] || fail "a replay duplicated the notification"
  [ "$(card_of sample-ship)" != "$card" ] || fail "a new hold reused the old card"
  pass "a committed result survives server restart and retries never release a re-asked question"
}

test_confirmation_storage_failure_reports_unknown() {
  local home body out real
  home=$(make_home receipt-fails)
  hold "$home" sample-ship --reason "Ship now?"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
"$real" "\$@" || exit \$?
if [ "\${1:-}" = unhold ] && [ "\${2:-}" = sample-ship ]; then
  printf 'unavailable\n' > "$home/state/board/answers"
fi
EOF
  chmod +x "$home/fakebin/tasks-axi"
  start_board "$home"
  # After unhold commits, the wrapper prevents creating the confirmation dir.
  body=$(answer_body sample-ship yes)
  out=$(post_answer "$body")
  expect_refusal "$out" 500 outcome_unknown "a failed confirmation claimed the answer was not recorded"
  body_of "$out" | jq -e '.message | startswith("Your answer was recorded")' >/dev/null \
    || fail "a confirmation storage failure misreported the committed answer: $out"
  task_show "$home" sample-ship | grep -F 'held: no' >/dev/null || fail "the storage failure test did not commit"
  out=$(post_answer "$body")
  expect_refusal "$out" 500 outcome_unknown "an unreadable confirmation retried the mutation"
  [ "$(inbox_notes "$home")" = 1 ] || fail "a failed confirmation duplicated the answer notification"
  pass "a committed answer with unavailable confirmation storage reports uncertainty and does not reapply"
}

test_a_home_that_never_opts_in_is_untouched() {
  local home stamp changed
  home=$(make_home opt-out)
  hold "$home" call-o --title "Close the duplicate PR?" --reason "Close duplicate PR 13? Recommend yes"
  task_show "$home" call-o | grep -F "Captain hold options" >/dev/null \
    && fail "a hold without declared options gained an options line"
  stamp="$TMP_ROOT/opt-out.stamp"
  : > "$stamp"
  sleep 1
  if in_home "$home" "$BOARD" status > "$home/../opt-out-status.out" 2>&1; then
    fail "status reported a board for a home that never started one"
  fi
  grep -F "not serving" "$home/../opt-out-status.out" >/dev/null || fail "status did not say no board is running"
  in_home "$home" "$BOARD" model > "$TMP_ROOT/opt-out-model.json" || fail "the read-only model failed"
  in_home "$home" "$BOARD" unit > "$TMP_ROOT/opt-out-unit.txt" || fail "the unit printer failed"
  grep -F "ExecStart=\"$ROOT/bin/fm-board.sh\" serve" "$TMP_ROOT/opt-out-unit.txt" >/dev/null \
    || fail "the printed unit does not run this home's board"
  changed=$(find "$home" -newer "$stamp" ! -type d -print)
  [ -z "$changed" ] || fail "reading the board for a home that never serves one wrote files: $changed"
  [ ! -e "$home/state/board" ] || fail "a home that never serves a board gained board state"
  [ ! -e "$home/state/inbox" ] || fail "a home that never serves a board gained inbox notes"
  task_show "$home" call-o | grep -F "held: yes" >/dev/null || fail "reading the board changed the hold"
  pass "a home that never starts the board gains no board state, notes, wakes, or backlog changes"
}

test_model_renders_a_fixture_snapshot
test_page_and_data_are_guarded
test_answer_requests_are_validated
test_tailscale_login_allowlist
test_answers_land_through_the_intake
test_same_second_answer_still_moves_to_answered
test_reasking_an_answered_call_never_offers_the_old_question
test_later_that_cannot_defer_is_still_recorded
test_failed_later_repair_is_not_success_or_answerable
test_declared_option_keeps_held_work_held
test_reask_during_an_answer_never_takes_the_old_click
test_board_without_logins_is_local_only
test_page_staleness_ignores_the_phone_clock
test_page_recovers_a_lost_committed_response
test_answer_replay_survives_restart_without_reapplying
test_confirmation_storage_failure_reports_unknown
test_a_home_that_never_opts_in_is_untouched
