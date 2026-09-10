#!/usr/bin/env bash
# fm-fork-boundary-check.sh - executable shuvbro identity and compatibility contract.
#
# Asserts canonical product identity, preserved upstream compatibility bytes,
# MIT provenance, no tracked private fleet paths, persona instruction
# rendering, and an exhaustive remaining-name inventory with no fallback class.
# docs/fork-boundary.md is the prose owner.
#
# Usage: fm-fork-boundary-check.sh [--root DIR]
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = --root ]; then
  [ -n "${2:-}" ] || { echo "fm-fork-boundary-check: --root requires a directory" >&2; exit 2; }
  ROOT="$(cd "$2" && pwd)"
fi
cd "$ROOT" || exit 1

fail() {
  printf 'fm-fork-boundary-check: %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

file_contains() {
  grep -F -q -- "$2" "$1"
}

file_not_contains() {
  ! grep -F -q -- "$2" "$1"
}

# --- provenance -------------------------------------------------------------

[ -f LICENSE ] || fail "LICENSE missing"
file_contains LICENSE "MIT License" || fail "LICENSE is not MIT"
file_contains LICENSE "Copyright (c) 2026 Kun Chen" || fail "LICENSE lost Kun Chen copyright"
ok "MIT provenance preserved"

# --- canonical product surfaces --------------------------------------------

file_contains README.md "shuvbro" || fail "README.md missing canonical product name"
file_contains README.md "github.com/shuv1337/shuvbro" || fail "README.md missing canonical clone URL"
file_contains README.md "docs/fork-boundary.md" || fail "README.md missing fork-boundary link"
file_not_contains README.md "git clone https://github.com/kunchenguid/firstmate" \
  || fail "README.md still installs from upstream clone URL"
file_not_contains README.md "assets/banner.png" \
  || fail "README.md still links the upstream FIRSTMATE banner"
file_contains AGENTS.md "# shuvbro" || fail "AGENTS.md title is not shuvbro"
file_contains VISION.md "shuvbro" || fail "VISION.md missing canonical product name"
file_not_contains VISION.md "first mate that carries out the captain" \
  || fail "VISION.md still uses the old first-mate/captain manifesto pairing"
file_contains GROK_BOT.md "shuvbro" || fail "GROK_BOT.md missing canonical product name"
file_contains CONTRIBUTING.md "github.com/shuv1337/shuvbro" \
  || fail "CONTRIBUTING.md missing canonical repository URL"
file_contains CONTRIBUTING.md "no-mistakes" \
  || fail "CONTRIBUTING.md dropped the no-mistakes review mandate"

reject_mandatory_address() {
  local f=$1
  file_not_contains "$f" 'Address the user as "captain" at least once' \
    || fail "$f still mandates captain address"
  file_not_contains "$f" 'Address the captain as "captain" at least once' \
    || fail "$f still mandates captain address"
  file_not_contains "$f" 'address them as "captain"' \
    || fail "$f still mandates captain address"
  file_not_contains "$f" "Use light nautical seasoning" \
    || fail "$f still mandates nautical seasoning"
  file_not_contains "$f" "required direct address to the captain" \
    || fail "$f still mandates captain address"
  file_not_contains "$f" "Captain, shipshape." \
    || fail "$f still mandates Captain, shipshape"
}

loaded_paths="AGENTS.md GROK_BOT.md VISION.md README.md bin/fm-brief.sh bin/fm-dod-lib.sh bin/fm-branch-prompt.sh bin/fm-supervision-instructions.sh bin/fm-session-start.sh"
for f in $loaded_paths; do
  [ -f "$f" ] || fail "loaded instruction path missing: $f"
  reject_mandatory_address "$f"
done
skill_count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  skill_count=$((skill_count + 1))
  reject_mandatory_address "$f"
done < <(find .agents/skills -name SKILL.md -print | LC_ALL=C sort)
[ "$skill_count" -gt 0 ] || fail "no loaded skill SKILL.md files found"
if grep -F "Captain's Call" .agents/skills/bearings/SKILL.md \
  .agents/skills/bearings/assets/board-template.html >/dev/null 2>&1; then
  fail "bearings still uses display phrase Captain's Call; visible label is Needs you"
fi
file_contains .agents/skills/bearings/assets/board-template.html "captains_call" \
  || fail "board template lost captains_call payload field"
file_contains .agents/skills/bearings/assets/board-template.html "Needs you" \
  || fail "board template missing Needs you display label"
ok "canonical product surfaces use shuvbro"

# New operator/public docs may not reintroduce upstream product install or
# mandatory captain address. Allowlisted docs keep historical or protocol text.
docs_allowlisted() {
  case "$1" in
    docs/verification/*|docs/fork-boundary.md|docs/captain-hold-lifecycle.md|docs/fm-test-portable-shards.md|docs/configuration.md|docs/documentation-audiences.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
while IFS= read -r f; do
  [ -n "$f" ] || continue
  docs_allowlisted "$f" && continue
  file_not_contains "$f" "git clone https://github.com/kunchenguid/firstmate" \
    || fail "$f reintroduces the upstream clone URL"
  reject_mandatory_address "$f"
done < <(find docs -name '*.md' -print | LC_ALL=C sort)
ok "non-allowlisted docs do not reintroduce upstream product identity"

# --- compatibility identifiers ---------------------------------------------

[ -x bin/fm-spawn.sh ] || fail "bin/fm-spawn.sh missing"
[ -x bin/fm-watch.sh ] || fail "bin/fm-watch.sh missing"
[ -x bin/fm-captain-hold.sh ] || fail "bin/fm-captain-hold.sh missing"
file_contains bin/fm-session-start.sh "FM_HOME" || fail "FM_HOME missing"
file_contains bin/fm-brief.sh "{FIRSTMATE_SPEC}" || fail "{FIRSTMATE_SPEC} placeholder missing"
file_contains bin/fm-operational-input.sh "FIRSTMATE_OP:" \
  || fail "FIRSTMATE_OP: prefix missing"
file_contains bin/fm-operational-input.sh "FM_INJECT_MARK=" \
  || fail "FM_INJECT_MARK missing"
file_contains bin/fm-operational-input.sh "[fm-from-firstmate]" \
  || fail "[fm-from-firstmate] marker missing"
file_contains bin/fm-branch-prompt.sh "fm-main-mirror" \
  || fail "fm-main-mirror missing"
file_contains bin/fm-branch-prompt.sh "[captain]" \
  || fail "[captain] mirror tag missing"
file_contains bin/fm-branch-prompt.sh "[main]" \
  || fail "[main] mirror tag missing"
file_contains bin/fm-branch-prompt.sh "verdict captain" \
  || fail "verdict captain protocol text missing"
file_contains bin/fm-brief.sh "## Captain's intent" \
  || fail "## Captain's intent heading missing from fm-brief.sh"
file_contains bin/fm-brief.sh "## Firstmate spec" \
  || fail "## Firstmate spec heading missing from fm-brief.sh"
file_contains bin/fm-dod-lib.sh "## Captain's intent" \
  || fail "## Captain's intent parse heading missing from fm-dod-lib.sh"
file_contains bin/fm-dod-lib.sh "## Firstmate spec" \
  || fail "## Firstmate spec parse heading missing from fm-dod-lib.sh"
file_contains AGENTS.md "data/captain.md" || fail "data/captain.md filename missing"
file_contains AGENTS.md "captain-shared.md" || fail "captain-shared.md filename missing"
file_contains .no-mistakes.yaml "disable_project_settings: true" \
  || fail ".no-mistakes.yaml lost disable_project_settings true"
file_contains .tasks.toml 'path = "data/backlog.md"' \
  || fail ".tasks.toml backlog path changed"
file_contains bin/fm-config-inherit-lib.sh "persona" \
  || fail "persona missing from inheritable config owner"
[ -d .agents/skills/firstmate-coding-guidelines ] \
  || fail "skill name firstmate-coding-guidelines was renamed"
[ -d .agents/skills/stuck-crewmate-recovery ] \
  || fail "skill name stuck-crewmate-recovery was renamed"
[ -d .agents/skills/captain-hold-lifecycle ] \
  || fail "skill name captain-hold-lifecycle was renamed"
[ -d .agents/skills/updatefirstmate ] \
  || fail "slash-command skill updatefirstmate was renamed"
[ -d .agents/skills/afk ] || fail "slash-command skill afk was renamed"
[ -d .agents/skills/bearings ] || fail "slash-command skill bearings was renamed"
[ -d .agents/skills/stow ] || fail "slash-command skill stow was renamed"
[ -d .agents/skills/ahoy ] || fail "slash-command skill ahoy was renamed"
grep -R -l -- 'FMX_' bin docs AGENTS.md >/dev/null \
  || fail "FMX_ Relay identifier missing"
grep -R -l -- 'fm-x-' bin >/dev/null \
  || fail "fm-x- Relay helper prefix missing"

sb_bins=$(find bin -maxdepth 1 \( -name 'sb-*' -o -name 'SB_*' \) -print)
[ -z "$sb_bins" ] || fail "unexpected sb-/SB_ automation aliases: $sb_bins"
if grep -E -n '(^|[^A-Z0-9_])SB_[A-Z0-9_]+' bin/*.sh bin/backends/*.sh 2>/dev/null | grep -v 'fm-fork-boundary-check.sh' >/dev/null; then
  fail "unexpected SB_ identifiers in bin scripts"
fi
ok "compatibility identifiers preserved"

# --- private paths not tracked ---------------------------------------------

tracked=$(git ls-files -- data state config projects .no-mistakes .env)
[ -z "$tracked" ] || fail "private fleet paths are tracked: $tracked"
ok "private fleet paths are untracked"

# --- remaining-name inventory (no fallback class) --------------------------

classify_path() {
  case "$1" in
    AGENTS.md|README.md|VISION.md|GROK_BOT.md|CONTRIBUTING.md|docs/fork-boundary.md|docs/configuration.md)
      printf '%s\n' canonical-or-schema
      ;;
    LICENSE|assets/*)
      printf '%s\n' provenance-asset
      ;;
    docs/verification/*)
      printf '%s\n' historical-verification
      ;;
    tests/*)
      printf '%s\n' test
      ;;
    bin/*|.pi/*|.omp/*|.claude/*|.cursor/*|.codex/*|.grok/*|.opencode/*)
      printf '%s\n' implementation
      ;;
    .agents/skills/firstmate-*/*|.agents/skills/updatefirstmate/*)
      printf '%s\n' compatibility-skill
      ;;
    .agents/skills/*)
      printf '%s\n' loaded-instruction
      ;;
    skills/*)
      printf '%s\n' public-skill
      ;;
    docs/*)
      printf '%s\n' docs
      ;;
    .github/*|.greptile/*|.no-mistakes.yaml|.tasks.toml)
      printf '%s\n' ci-or-config
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

unclassified_files=
inventory_tmp=$(mktemp)
git grep -l -i -E 'firstmate|kunchenguid/firstmate|first[[:space:]]+mate' -- . >"$inventory_tmp" || true
while IFS= read -r path; do
  [ -n "$path" ] || continue
  class=$(classify_path "$path")
  if [ "$class" = unclassified ]; then
    unclassified_files="${unclassified_files}${path}"$'\n'
  fi
done < "$inventory_tmp"
rm -f "$inventory_tmp"
if [ -n "$unclassified_files" ]; then
  printf '%s\n' "$unclassified_files" >&2
  fail "remaining firstmate matches lack an inventory class"
fi
ok "remaining-name inventory is fully classified"

# --- persona rendering -----------------------------------------------------

PERSONA="$ROOT/bin/fm-persona-lib.sh"
if [ ! -x "$PERSONA" ]; then
  fail "bin/fm-persona-lib.sh missing"
fi
home=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-boundary-persona.XXXXXX")
cleanup() { rm -rf "$home"; }
trap cleanup EXIT
mkdir -p "$home/a/config" "$home/b/config"

dump=$(FM_HOME="$home/a" FM_CONFIG_OVERRIDE="$home/a/config" "$PERSONA" --dump) \
  || fail "absent persona config should default"
printf '%s\n' "$dump" | grep -qx 'preset=bro' || fail "absent config did not default to bro"
printf '%s\n' "$dump" | grep -qx 'lead=Bro' || fail "absent config lost default lead Bro"
printf '%s\n' "$dump" | grep -qx 'user=dude' || fail "absent config lost default user dude"

printf 'preset=neutral\n' > "$home/a/config/persona"
dump=$(FM_HOME="$home/a" FM_CONFIG_OVERRIDE="$home/a/config" "$PERSONA" --dump) \
  || fail "neutral preset failed"
printf '%s\n' "$dump" | grep -qx 'preset=neutral' || fail "neutral preset not applied"

printf 'preset=dzl\n' > "$home/a/config/persona"
dump=$(FM_HOME="$home/a" FM_CONFIG_OVERRIDE="$home/a/config" "$PERSONA" --dump) \
  || fail "dzl preset failed"
printf '%s\n' "$dump" | grep -qx "success_opener=AYO, PR'S HERE" \
  || fail "dzl success opener missing"

printf 'lead=Skip\npreset=neutral\n' > "$home/a/config/persona"
dump=$(FM_HOME="$home/a" FM_CONFIG_OVERRIDE="$home/a/config" "$PERSONA" --dump) \
  || fail "override-before-preset failed"
printf '%s\n' "$dump" | grep -qx 'preset=neutral' || fail "preset after override lost"
printf '%s\n' "$dump" | grep -qx 'lead=Skip' || fail "earlier lead override was dropped"
printf '%s\n' "$dump" | grep -qx 'user=user' || fail "neutral user lost after ordered override"

printf 'preset=nope\n' > "$home/a/config/persona"
if FM_HOME="$home/a" FM_CONFIG_OVERRIDE="$home/a/config" "$PERSONA" --validate >/dev/null 2>"$home/err"; then
  fail "invalid preset silently succeeded"
fi
grep -q 'invalid config' "$home/err" || fail "invalid preset did not report invalid config"

printf 'preset=bro\n' > "$home/a/config/persona"
printf 'preset=neutral\n' > "$home/b/config/persona"
dump_a=$(FM_HOME="$home/a" FM_CONFIG_OVERRIDE="$home/a/config" "$PERSONA" --preset)
dump_b=$(FM_HOME="$home/b" FM_CONFIG_OVERRIDE="$home/b/config" "$PERSONA" --preset)
[ "$dump_a" = bro ] || fail "home A persona leaked"
[ "$dump_b" = neutral ] || fail "home B persona leaked"

block=$(FM_HOME="$home/missing" FM_CONFIG_OVERRIDE="$home/missing/config" "$PERSONA" --block)
printf '%s\n' "$block" | grep -qx 'product: shuvbro' || fail "PERSONA block missing product"
printf '%s\n' "$block" | grep -qx 'preset: bro' || fail "PERSONA block missing default preset"
ok "persona instruction rendering"

printf 'fm-fork-boundary-check: ok\n'
