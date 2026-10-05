#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Ship and scout `# Task` sections have two subsections Firstmate
# fills before dispatch: `{TASK}` under `## Captain's intent` (the captain's
# own ask plus the context needed to read it, including the substance of any
# report, decision, or PR the ask refers to) and `{FIRSTMATE_SPEC}`
# under `## Firstmate spec` (build instructions, which are never the captain's
# intent). bin/fm-dod-lib.sh owns the no-mistakes `--intent` contract those
# subsections feed; bin/fm-spawn.sh refuses leftover placeholders. Secondmate
# charters still use a single `{TASK}` charter fill. Firstmate may adjust other
# sections when the task genuinely deviates (e.g. working an existing external
# PR instead of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--herdr-lab] [--allow-write <path>]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --allow-write <path> is repeatable on scout scaffolds only.
#   It rewrites the scout stay-inside rule so the worker may also write the
#   named path and the files inside it, and nothing broader.
#   A leading ~/ expands to $HOME; every other relative form is refused.
#   Refuses `/`, $HOME itself, the primary checkout, and any projects/ clone,
#   including a path inside one, a path that contains one, and this home's
#   projects/ directory even when no clone is there yet.
#   Those roots and the allowed path are resolved physically, the same way pwd -P
#   does, so a symlink or a later .. segment cannot name a broader tree.
#   A newline, carriage return, or backtick is refused on the flag, on each
#   symlink target, and on the resolved path.
#   The primary checkout is this repo's main worktree and the physical path of
#   the checkout these scripts run from, plus the main worktree of a projects/
#   clone when that clone is a linked worktree of another checkout.
#   Ship scaffolds and secondmate charters refuse the flag.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} and {FIRSTMATE_SPEC} are filled
#   after scaffolding and the caller-supplied repo string cannot reliably
#   identify this repo. Briefs made without it carry a loud declaration so an
#   omitted contract cannot be silent.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line. bin/fm-spawn.sh reads that line and refuses
# to launch a ship task whose explicit --mode disagrees, so an adjusted brief and the
# recorded task metadata cannot drift apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# --mode is refused on scout and secondmate scaffolds: a scout's deliverable is a
# report rather than a merge, and a charter is not a delivery contract.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and firstmate-side input only (AGENTS.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship and scout scaffolds, including those passed --herdr-lab, forbid contacting
# the captain directly. Questions go to firstmate as a keyed status line.
# bin/fm-sharkctl-guard.sh refuses sharkctl notify and ask in panes fm-spawn
# marks with FM_TASK_ID.
# Every scaffold also carries the steering-inbox receive-and-ack section:
# process state/<id>.inbox/*.msg in order and acknowledge each by moving it to
# handled/ (record, doorbell, and ladder owned by bin/fm-task-inbox-lib.sh).
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path.
# That section runs fm-ensure-agents-md.sh only when the task produced that
# knowledge. The helper owns file-convention handling: it leaves an existing
# CLAUDE.md symlink in place and does not retrofit self-governance onto an
# AGENTS.md that does not already carry it. The section also carries the
# AGENTS.md authoring bar (widely useful knowledge only, pointers over copied
# detail).
# Scaffolds carry no role scope: fm-spawn.sh supplies fm_brief_worker_role from
# fm-dod-lib.sh to every ship/scout launch brief, so this file never becomes a
# second owner of a contract that must stay current across relaunches.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

# --allow-write contract: header comment above is the owner. These helpers only
# enforce it. The allowed path is walked in order and resolved physically, so a
# symlink is followed before a later .. segment, matching pwd -P.
lexical_abs_path() {
  local input=$1 part out
  case "$input" in
    /*) ;;
    *) echo "error: --allow-write requires an absolute path (got '$input')" >&2; return 1 ;;
  esac
  input=${input#/}
  out=
  while [ -n "$input" ]; do
    case "$input" in
      /*) input=${input#/}; continue ;;
    esac
    part=${input%%/*}
    case "$input" in
      */*) input=${input#*/} ;;
      *) input= ;;
    esac
    case "$part" in
      ''|.) continue ;;
      ..)
        if [ -n "$out" ]; then
          out=${out%/*}
        fi
        ;;
      *) out="$out/$part" ;;
    esac
  done
  [ -n "$out" ] || out=/
  printf '%s\n' "$out"
}

expand_allow_write_input() {
  local input=$1 home rest tilde prefix
  # Literal tilde, not this shell's HOME. The brief names the expanded path.
  # shellcheck disable=SC2088
  tilde='~'
  prefix="$tilde/"
  home=${HOME:-}
  if [ "$input" = "$tilde" ]; then
    [ -n "$home" ] || { echo "error: --allow-write cannot expand '~' because HOME is unset" >&2; return 1; }
    printf '%s\n' "$home"
    return 0
  fi
  rest=${input#"$prefix"}
  if [ "$rest" != "$input" ]; then
    [ -n "$home" ] || { echo "error: --allow-write cannot expand '~' because HOME is unset" >&2; return 1; }
    home=${home%/}
    printf '%s\n' "$home/$rest"
    return 0
  fi
  case "$input" in
    /*) printf '%s\n' "$input" ;;
    *) echo "error: --allow-write requires an absolute path (got '$input')" >&2; return 1 ;;
  esac
}

allow_write_text_is_unsafe() {
  # $'\n' cannot be captured with command substitution; that strips the newline
  # and the pattern then matches every path.
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\140'*) return 0 ;;
  esac
  return 1
}

refuse_unsafe_allow_write_text() {
  if allow_write_text_is_unsafe "$1"; then
    echo "error: --allow-write path contains a character the brief cannot quote safely" >&2
    return 1
  fi
}

readlink_exact() {
  local target
  # Preserve a trailing newline that command substitution would otherwise strip.
  target=$(readlink "$1"; printf x) || return 1
  printf '%s' "${target%x}"
}

canonicalize_allow_path() {
  local input=$1 depth=${2:-0} out part combined target parent
  [ "$depth" -lt 40 ] || { echo "error: --allow-write path has a symlink loop" >&2; return 1; }
  case "$input" in
    /*) ;;
    *) echo "error: --allow-write requires an absolute path (got '$input')" >&2; return 1 ;;
  esac
  refuse_unsafe_allow_write_text "$input" || return 1
  input=${input#/}
  out=
  while [ -n "$input" ]; do
    case "$input" in
      /*) input=${input#/}; continue ;;
    esac
    part=${input%%/*}
    case "$input" in
      */*) input=${input#*/} ;;
      *) input= ;;
    esac
    case "$part" in
      ''|.) continue ;;
      ..)
        if [ -n "$out" ] && [ -d "$out" ]; then
          out=$(CDPATH='' cd -P -- "$out" && pwd -P) || {
            echo "error: --allow-write path cannot be resolved: $out" >&2
            return 1
          }
        fi
        if [ -n "$out" ]; then
          out=${out%/*}
          [ -n "$out" ] || out=/
        fi
        continue
        ;;
    esac
    if [ -z "$out" ]; then
      combined="/$part"
    else
      combined="$out/$part"
    fi
    if [ -L "$combined" ]; then
      target=$(readlink_exact "$combined") || {
        echo "error: --allow-write path cannot be resolved: $combined" >&2
        return 1
      }
      refuse_unsafe_allow_write_text "$target" || return 1
      case "$target" in
        /*) ;;
        *)
          if [ -n "$out" ]; then
            target="$out/$target"
          else
            target="/$target"
          fi
          ;;
      esac
      refuse_unsafe_allow_write_text "$target" || return 1
      if [ -n "$input" ]; then
        target="$target/$input"
      fi
      canonicalize_allow_path "$target" "$((depth + 1))" || return 1
      return 0
    fi
    out=$combined
  done
  if [ -n "$out" ] && [ -d "$out" ]; then
    out=$(CDPATH='' cd -P -- "$out" && pwd -P) || {
      echo "error: --allow-write path cannot be resolved: $out" >&2
      return 1
    }
  elif [ -n "$out" ] && [ -e "$out" ]; then
    parent=$(CDPATH='' cd -P -- "$(dirname "$out")" && pwd -P) || {
      echo "error: --allow-write path cannot be resolved: $out" >&2
      return 1
    }
    if [ "$parent" = / ]; then
      out="/$(basename "$out")"
    else
      out="$parent/$(basename "$out")"
    fi
  fi
  [ -n "$out" ] || out=/
  refuse_unsafe_allow_write_text "$out" || return 1
  printf '%s\n' "$out"
}

allow_write_paths_overlap() {
  local left=$1 right=$2
  [ -n "$left" ] && [ -n "$right" ] || return 1
  [ "$left" = "$right" ] && return 0
  case "$left" in
    "$right"/*) return 0 ;;
  esac
  case "$right" in
    "$left"/*) return 0 ;;
  esac
  return 1
}

add_forbidden_write_root() {
  local kind=$1 path=$2 i
  [ -n "$path" ] || return 0
  if [ "${#FORBIDDEN_WRITE_PATH[@]}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "${#FORBIDDEN_WRITE_PATH[@]}" ]; do
      if [ "${FORBIDDEN_WRITE_PATH[$i]}" = "$path" ]; then
        return 0
      fi
      i=$((i + 1))
    done
  fi
  FORBIDDEN_WRITE_KIND+=("$kind")
  FORBIDDEN_WRITE_PATH+=("$path")
}

canonical_dir() {
  local dir=$1
  [ -d "$dir" ] || return 1
  CDPATH='' cd -P -- "$dir" && pwd -P
}

git_primary_worktree() {
  local repo=$1 line
  line=$(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10); exit}') || line=
  [ -n "$line" ] || return 1
  canonical_dir "$line" || return 1
}

collect_forbidden_write_roots() {
  local primary projects clone resolved main home_phys root_phys
  FORBIDDEN_WRITE_KIND=()
  FORBIDDEN_WRITE_PATH=()
  root_phys=$(canonical_dir "$FM_ROOT" || true)
  add_forbidden_write_root primary "$root_phys"
  primary=
  if [ -d "$FM_ROOT" ]; then
    primary=$(git_primary_worktree "$FM_ROOT" || true)
  fi
  if [ -z "$primary" ]; then
    primary=$root_phys
  fi
  add_forbidden_write_root primary "$primary"
  home_phys=$(canonical_dir "$FM_HOME" || true)
  if [ -n "$home_phys" ] && [ -d "$home_phys/projects" ]; then
    projects=$(canonical_dir "$home_phys/projects" || true)
  elif [ -n "$home_phys" ]; then
    projects="$home_phys/projects"
  else
    projects=$(lexical_abs_path "$FM_HOME/projects" || true)
  fi
  add_forbidden_write_root projects "$projects"
  if [ -n "$projects" ] && [ -d "$projects" ]; then
    while IFS= read -r clone; do
      [ -n "$clone" ] || continue
      [ -d "$clone" ] || continue
      resolved=$(canonical_dir "$clone" || true)
      add_forbidden_write_root projects "$resolved"
      main=$(git_primary_worktree "$clone" || true)
      add_forbidden_write_root primary "$main"
    done < <(find "$projects" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print 2>/dev/null || true)
  fi
}

refuse_allow_write_path() {
  local canon=$1 home_canon i matched
  [ "$canon" != / ] || { echo "error: --allow-write refuses '/'" >&2; return 1; }
  home_canon=
  if [ -n "${HOME:-}" ]; then
    if [ -d "$HOME" ]; then
      home_canon=$(canonical_dir "$HOME" || true)
    fi
    if [ -z "$home_canon" ]; then
      home_canon=$(lexical_abs_path "$HOME" || true)
    fi
  fi
  if [ -n "$home_canon" ] && [ "$canon" = "$home_canon" ]; then
    echo "error: --allow-write refuses the home directory itself" >&2
    return 1
  fi
  matched=
  if [ "${#FORBIDDEN_WRITE_PATH[@]}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "${#FORBIDDEN_WRITE_PATH[@]}" ]; do
      if allow_write_paths_overlap "$canon" "${FORBIDDEN_WRITE_PATH[$i]}"; then
        if [ "${FORBIDDEN_WRITE_KIND[$i]}" = primary ]; then
          echo "error: --allow-write refuses the primary checkout or a path that contains it" >&2
          return 1
        fi
        matched=projects
      fi
      i=$((i + 1))
    done
  fi
  if [ -n "$matched" ]; then
    echo "error: --allow-write refuses a projects/ clone or a path that contains one" >&2
    return 1
  fi
}

append_allow_write_canon() {
  local path=$1 i
  if [ "${#ALLOW_WRITE_CANON[@]}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "${#ALLOW_WRITE_CANON[@]}" ]; do
      [ "${ALLOW_WRITE_CANON[$i]}" = "$path" ] && return 0
      i=$((i + 1))
    done
  fi
  ALLOW_WRITE_CANON+=("$path")
}

validate_allow_write() {
  local raw expanded canon i
  ALLOW_WRITE_CANON=()
  if [ "${#ALLOW_WRITE[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "$KIND" != scout ]; then
    echo "error: --allow-write applies only to scout briefs; ship and secondmate scaffolds refuse it" >&2
    return 1
  fi
  collect_forbidden_write_roots
  i=0
  while [ "$i" -lt "${#ALLOW_WRITE[@]}" ]; do
    raw=${ALLOW_WRITE[$i]}
    i=$((i + 1))
    [ -n "$raw" ] || { echo "error: --allow-write requires an absolute path (got '')" >&2; return 1; }
    refuse_unsafe_allow_write_text "$raw" || return 1
    expanded=$(expand_allow_write_input "$raw") || return 1
    refuse_unsafe_allow_write_text "$expanded" || return 1
    canon=$(canonicalize_allow_path "$expanded") || return 1
    refuse_unsafe_allow_write_text "$canon" || return 1
    refuse_allow_write_path "$canon" || return 1
    append_allow_write_canon "$canon"
  done
}

format_stay_inside_rule() {
  local path i
  if [ "${#ALLOW_WRITE_CANON[@]}" -eq 0 ]; then
    printf '%s\n' "2. Stay inside this worktree; the only files you may write outside it are the report and the status file below."
    return 0
  fi
  printf '%s\n' "2. Stay inside this worktree; the only files you may write outside it are the report and the status file below, plus these exact paths and the files inside them, and nothing broader:"
  i=0
  while [ "$i" -lt "${#ALLOW_WRITE_CANON[@]}" ]; do
    path=${ALLOW_WRITE_CANON[$i]}
    printf '%s\n' "   - \`$path\`"
    i=$((i + 1))
  done
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
MODE=
MODE_SET=0
ALLOW_WRITE=()
ALLOW_WRITE_CANON=()
FORBIDDEN_WRITE_KIND=()
FORBIDDEN_WRITE_PATH=()
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      allow-write) ALLOW_WRITE+=("$a") ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --allow-write) want_value=allow-write ;;
    --allow-write=*) ALLOW_WRITE+=("${a#--allow-write=}") ;;
    # yolo never reaches the worker: it is firstmate's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Ship delivery mode is an explicit per-task decision (AGENTS.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

validate_allow_write || exit 1

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

ASK_USER_BLOCK=
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  ASK_USER_BLOCK=$(fm_ask_user_escalation_block "$DATA" "$ID")
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
INBOX_DIR=$(shell_quote "$STATE/$ID.inbox")

# The receive-and-ack half of the steering-inbox contract, included in every
# scaffold kind. The record format, doorbell line, and re-ring ladder are
# owned by bin/fm-task-inbox-lib.sh; the doorbell itself is self-describing,
# so this section is reinforcement for the natural-checkpoint habit, not the
# only carrier of the instruction.
IFS= read -r -d '' INBOX_SECTION <<EOF || true
# Firstmate instruction inbox
Firstmate steers you through durable message files in $INBOX_DIR.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list $INBOX_DIR/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: \`mv $INBOX_DIR/NNN.msg $INBOX_DIR/handled/\`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.
EOF
INBOX_SECTION=${INBOX_SECTION%$'\n'}

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
SECOND_ROLE=$(fm_brief_secondmate_role) || exit 1
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main lead. Work on your own; do not wait for a human.

$SECOND_ROLE

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated shuvbro home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own workers with the normal lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main lead routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# The user and the parent channel
Nobody reads this chat: the user and the main lead see only what is appended to $STATUS_FILE, and a user-facing sentence that is not appended there has not been sent.
That file is your parent channel: every sentence you would say to the user, and every outcome the local AGENTS.md tells the lead to bring to the user, is one appended line there, never chat.
Your own machinery publishes the durable facts about your crew's work for you (\`bin/fm-parent-channel-lib.sh\`): a child's terminal done or failed line with its note and PR on every supervision poll, a PR-ready line when you register a PR, a task you hold for the captain and its answer, a merge, and a child's final line at cleanup all reach the parent channel from the scripts that record them, whether or not you append anything.
What only you can append is judgement: the answer to a marked request below, a recommendation or caveat on a delivered outcome, a blocker or failure of your own, and anything else you would otherwise say to the captain.

# Requests from the main lead
You are a lead in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main lead is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main lead does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh <verb> <corr_id> <note>\` appends that correlated line to the parent channel itself - do not pass a status path, and do not write a hand path under this home.
A plain \`echo\` that includes the same \`corr=<id>\` on this parent channel is equally valid; do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main lead is woken and can read it.
Before treating an investigation or visual review as complete, load \`captain-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the user typing directly into your pane: treat it as authoritative user intervention and stay conversational; do not force it onto the status path.
A request arriving through the instruction inbox below follows the same marker and reply rules.

$INBOX_SECTION

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own, naming when it clears with \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) when you know; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, work ready for review, or work you landed.
Work you landed includes a merge you performed yourself under standing merge authority and one the captain merged on the forge: under that authority nothing is ever \"ready for review\", so a landed merge that goes unreported reaches the captain as silence.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main firstmate's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main firstmate, append \`resolved: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight workers, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main lead to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

# Shared by the ship and scout scaffolds, including --herdr-lab. Quoted heredoc
# so the backticks reach the brief as text. Secondmate charters are leads in
# their own home and are not marked with FM_TASK_ID, so they do not carry this
# worker rule.
IFS= read -r -d '' CAPTAIN_CONTACT_RULE <<'EOF' || true
8. Never contact the captain.
   Do not run `sharkctl`, and do not use any other notification, email, chat, or phone tool.
   Do not address the captain in a pull request or an issue.
   Every question goes to firstmate as a keyed status line (`needs-decision [key=<slug>]: {the question}`), then stop.
EOF
CAPTAIN_CONTACT_RULE=${CAPTAIN_CONTACT_RULE%$'\n'}

IFS= read -r -d '' TASK_SECTION <<'EOF' || true
# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}
EOF
TASK_SECTION=${TASK_SECTION%$'\n'}
ROLE_INTRO=$(fm_brief_agent_intro "$KIND") || exit 1

if [ "$KIND" = scout ]; then
STAY_INSIDE_RULE=$(format_stay_inside_rule) || exit 1
cat > "$BRIEF" <<EOF
$ROLE_INTRO

$TASK_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
$STAY_INSIDE_RULE
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; firstmate
   copies that URL from your line rather than assembling one.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. When you know when the wait clears, say so in the line with
   \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) and firstmate rechecks at that time instead.
   Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs; only firstmate
   manages the daemon.
   Before you append \`blocked:\` about the pipeline, run \`no-mistakes daemon status\` and
   \`no-mistakes axi status\`. If the daemon socket refuses connections or is missing, append
   \`blocked: {the daemon error}\` and stop even when the local run record still says running or
   fixing, because that record can be stale after the daemon exits. A run record failed with a
   daemon error is also a real block.
   Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
   going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
   the daemon accepts \`respond\` immediately and runs the round in the background, so a killed or
   timed-out call was only waiting for a read while the run kept working.

$CAPTAIN_CONTACT_RULE

$INBOX_SECTION

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
If your deliverable is a visual artifact the captain will review and iterate on, you may host the Lavish review loop yourself (poll, revise, re-serve, staying alive) instead of handing it back to firstmate.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/captain-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK} and {FIRSTMATE_SPEC})"
exit 0
fi

# Ship task: shape Setup / Rule 1 by this task's explicit delivery mode, validated
# above, and render the Definition of done from its single owner, bin/fm-dod-lib.sh,
# which bin/fm-promote.sh renders too so a promoted scout receives the same contract.
# The block opens with the fixed "Delivery contract: mode=<mode>" line that
# bin/fm-spawn.sh checks against its own explicit --mode before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    ;;
esac
DOD=$(fm_dod_block "$MODE" "$ID") || exit 1

cat > "$BRIEF" <<EOF
$ROLE_INTRO

$TASK_SECTION

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; firstmate
   copies that URL from your line rather than assembling one.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
$ASK_USER_BLOCK
   A decision or blocker you opened stays open until a \`resolved\` line carrying its exact key lands; a later \`done:\` or \`working:\` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append \`resolved: {how it cleared}\` yourself (same \`[key=<slug>]\` if you opened it with one) as you resume.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs; only firstmate
   manages the daemon.
   Before you append \`blocked:\` about the pipeline, run \`no-mistakes daemon status\` and
   \`no-mistakes axi status\`. If the daemon socket refuses connections or is missing, append
   \`blocked: {the daemon error}\` and stop even when the local run record still says running or
   fixing, because that record can be stale after the daemon exits. A run record failed with a
   daemon error is also a real block.
   Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
   going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
   the daemon accepts \`respond\` immediately and runs the round in the background, so a killed or
   timed-out call was only waiting for a read while the run kept working.

$CAPTAIN_CONTACT_RULE

$INBOX_SECTION

# Project memory
Run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree only when this task produced durable project-intrinsic knowledge to record in \`AGENTS.md\`.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\`, follow \`$FM_ROOT/bin/fm-ensure-agents-md.sh\`'s self-governance contract in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK} and {FIRSTMATE_SPEC})"
