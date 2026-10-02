#!/usr/bin/env bash
# Start a persistent unattended shuvcode worker with an explicit model.
# Usage: fm-opencode-v2-launch.sh --model provider/model[#variant] --prompt <brief>
#
# The root TUI accepts --auto but not --model; mini accepts --model but lacks
# --auto. Keep one private stdin-leased server alive, verify its loaded model
# catalog, create a model-bound root session, and attach the root --auto TUI.
# The server exits on lease EOF after the TUI exits; shared services are unused.
# A fresh in-memory password authenticates the loopback connection and shuvcode
# strips it from tool environments. No credentials are printed or persisted.
# fm-spawn owns execution-event proof and the older prefill/Enter fallback.
# FM_OPENCODE_V2_CATALOG_POLLS (default 60, 250 ms each) bounds catalog startup.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: fm-opencode-v2-launch.sh --model provider/model[#variant] --prompt <brief>'
}

model_ref='' prompt='' have_prompt=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--prompt)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      if [ "$1" = --model ]; then
        model_ref=$2
      else
        prompt=$2
        have_prompt=1
      fi
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

model=${model_ref%%#*}
variant=''
case "$model_ref" in
  *'#'*)
    variant=${model_ref#*#}
    case "$variant" in ''|*'#'*) usage >&2; exit 2 ;; esac
    ;;
esac
case "$model" in
  ''|/*|*/|*[![:print:]]*) usage >&2; exit 2 ;;
  */*) ;;
  *) usage >&2; exit 2 ;;
esac
[ "$have_prompt" -eq 1 ] || { usage >&2; exit 2; }
provider=${model%%/*}
model=${model#*/}
directory=$(pwd -P)
polls=${FM_OPENCODE_V2_CATALOG_POLLS:-60}
case "$polls" in ''|*[!0-9]*|0) usage >&2; exit 2 ;; esac
lease_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-shuvcode-lease.XXXXXX")
server_pid=''
cleanup() {
  local status=$?
  exec 3>&-
  if [ -n "$server_pid" ]; then
    wait "$server_pid" || true
  fi
  rm -rf "$lease_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
lease_password=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("hex"))')
mkfifo "$lease_dir/stdin"
OPENCODE_PASSWORD="$lease_password" OPENCODE_SERVER_PASSWORD="$lease_password" \
  shuvcode serve --stdio --hostname 127.0.0.1 --port 0 < "$lease_dir/stdin" > "$lease_dir/ready" &
server_pid=$!
exec 3> "$lease_dir/stdin"
url=''
for ((i=0; i<100; i++)); do
  url=$(jq -er '.url | select(type=="string" and test("^http://127[.]0[.]0[.]1:[0-9]+/?$"))' "$lease_dir/ready" 2>/dev/null) || url=''
  [ -z "$url" ] || break
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
[ -n "$url" ] || { printf '%s\n' 'error: private shuvcode server did not become ready' >&2; exit 1; }
client() {
  OPENCODE_PASSWORD="$lease_password" OPENCODE_SERVER_PASSWORD="$lease_password" shuvcode "$@" 3>&-
}
# Catalog snapshots can precede initial plugin settlement. Poll the SAME leased
# server; separate --standalone reads would restart that cold snapshot forever.
selected=''
for ((i=0; i<polls; i++)); do
  # CLI api output can truncate this large catalog on exit. Read the same
  # authenticated loopback API with Node, already required by the launcher,
  # and emit only the requested model. No extra client dependency is added.
  selected=$(OPENCODE_PASSWORD="$lease_password" node - "$url" "$provider" "$model" 3>&- <<'JS'
const http = require("node:http");
const [url, provider, model] = process.argv.slice(2);
const authorization = "Basic " + Buffer.from("opencode:" + process.env.OPENCODE_PASSWORD).toString("base64");
const request = http.get(url + "/api/model", { headers: { authorization } }, (response) => {
  let body = "";
  response.setEncoding("utf8");
  response.on("data", (chunk) => { body += chunk; });
  response.on("end", () => {
    try {
      if (response.statusCode !== 200) throw new Error("catalog HTTP " + response.statusCode);
      const selected = JSON.parse(body).data.find((item) => item.providerID === provider && item.id === model);
      if (selected) process.stdout.write(JSON.stringify(selected));
    } catch {
      console.error("error: invalid shuvcode model catalog response");
      process.exitCode = 1;
    }
  });
});
request.setTimeout(10000, () => request.destroy(new Error("catalog timeout")));
request.on("error", () => { console.error("error: shuvcode model catalog request failed"); process.exitCode = 1; });
JS
  ) || exit 1
  [ -z "$selected" ] || break
  sleep 0.25
done
[ -n "$selected" ] || { printf 'error: shuvcode model unavailable: %s/%s\n' "$provider" "$model" >&2; exit 1; }
if [ -n "$variant" ] && ! printf '%s' "$selected" | jq -e --arg variant "$variant" \
  'any(.variants[]?; .id==$variant)' >/dev/null; then
  printf 'error: shuvcode variant unavailable: %s\n' "$model_ref" >&2
  exit 1
fi
body=$(jq -cn --arg directory "$directory" --arg provider "$provider" \
  --arg model "$model" --arg variant "$variant" '
  {location:{directory:$directory},model:{providerID:$provider,id:$model}}
  | if $variant != "" then .model.variant=$variant else . end
')
if ! response=$(client api --server "$url" session.create --data "$body"); then
  printf '%s\n' 'error: could not create the requested shuvcode worker session' >&2
  exit 1
fi
if ! session=$(printf '%s' "$response" | jq -er --arg directory "$directory" \
  --arg provider "$provider" --arg model "$model" --arg variant "$variant" '
  .data
  | select(.parentID == null and .location.directory == $directory
      and .model.providerID == $provider and .model.id == $model
      and (.model.variant // "") == $variant)
  | .id | select(type == "string" and test("^ses[a-zA-Z0-9_-]+$"))
'); then
  printf '%s\n' 'error: shuvcode did not return the requested model-bound root session' >&2
  exit 1
fi
client --server "$url" --auto --session "$session" --prompt "$prompt"
