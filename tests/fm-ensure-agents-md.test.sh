#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

# Public contract: CLAUDE.md is this exact two-line pointer, never a symlink.
assert_claude_pointer() {
  local path=$1
  [ -e "$path" ] || fail "CLAUDE.md is missing"
  [ ! -L "$path" ] || fail "CLAUDE.md is a symlink; expected a real @AGENTS.md pointer file"
  [ -f "$path" ] || fail "CLAUDE.md is not a regular file"
  cmp -s "$path" - <<'EOF' || fail "CLAUDE.md is not the canonical @AGENTS.md pointer"
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

write_fixture_claude_pointer() {
  cat > "$1/CLAUDE.md" <<'EOF'
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
}

test_created_agents_md_includes_self_governance() {
  local repo agents
  repo="$TMP_ROOT/new-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for empty project"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created"
  assert_claude_pointer "$repo/CLAUDE.md"
  assert_grep "## Maintaining this file" "$agents" "self-governance section heading missing"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "self-governance section lost the future-session bar"
  assert_grep "Do not repeat what the codebase already shows; point to the authoritative file or command instead." "$agents" \
    "self-governance section lost pointer-over-copy guidance"
  assert_grep "Prefer rewriting or pruning existing entries over appending new ones." "$agents" \
    "self-governance section lost rewrite-or-prune guidance"
  assert_grep "When updating this file, preserve this bar for all agents and keep entries concise." "$agents" \
    "self-governance section lost all-agents maintenance guidance"
  pass "fm-ensure-agents-md.sh: created AGENTS.md includes self-governance section"
}

test_fresh_setup_writes_real_claude_pointer() {
  local repo out
  repo="$TMP_ROOT/fresh-pointer-project"
  mkdir -p "$repo"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed creating a fresh pointer"
  assert_contains "$out" "created:" "fresh setup did not report created"
  assert_claude_pointer "$repo/CLAUDE.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "fresh setup created a CLAUDE.md symlink"
  pass "fm-ensure-agents-md.sh: fresh setup writes a real @AGENTS.md pointer"
}

test_promoted_claude_md_keeps_existing_content() {
  local repo agents count
  repo="$TMP_ROOT/claude-project"
  mkdir -p "$repo"
  cat > "$repo/CLAUDE.md" <<'EOF'
# Existing agent memory

Run tests with `make test`.
EOF
  cp "$repo/CLAUDE.md" "$repo/.before"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created during promotion"
  assert_claude_pointer "$repo/CLAUDE.md"
  cmp -s "$repo/.before" "$agents" \
    || fail "promotion appended self-governance or rewrote existing CLAUDE.md content"
  assert_grep "Run tests with \`make test\`." "$agents" \
    "promotion lost existing CLAUDE.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 0 ] || fail "promotion wrote $count self-governance sections onto existing content"
  pass "fm-ensure-agents-md.sh: promoted CLAUDE.md keeps its content without a new self-governance section"
}

test_promoted_claude_md_preserves_original_bytes() {
  local repo agents
  repo="$TMP_ROOT/no-trailing-newline-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nRun tests with make test.' > "$repo/CLAUDE.md"
  cp "$repo/CLAUDE.md" "$repo/.before"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for newline-less CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  cmp -s "$repo/.before" "$agents" \
    || fail "newline-less promotion rewrote existing CLAUDE.md bytes"
  assert_claude_pointer "$repo/CLAUDE.md"
  pass "fm-ensure-agents-md.sh: promotion preserves original CLAUDE.md bytes"
}

test_existing_agents_md_with_symlink_stays_put() {
  local repo agents out count
  repo="$TMP_ROOT/existing-symlinked-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nBuild with make.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md with symlink"
  assert_contains "$out" "unchanged:" "existing CLAUDE.md symlink was not left unchanged"
  assert_contains "$out" "kept existing CLAUDE.md symlink" "existing CLAUDE.md symlink was replaced"
  cmp -s "$repo/.before" "$agents" \
    || fail "existing symlinked AGENTS.md gained or lost content"
  assert_grep "Build with make." "$agents" "existing AGENTS.md content was dropped"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 0 ] || fail "existing symlinked AGENTS.md gained $count self-governance sections"
  [ -L "$repo/CLAUDE.md" ] || fail "existing CLAUDE.md symlink was replaced with a regular file"
  [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "existing CLAUDE.md symlink was retargeted"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run"
  assert_contains "$out" "unchanged:" "idempotent re-run did not report unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "idempotent re-run modified AGENTS.md"
  [ -L "$repo/CLAUDE.md" ] || fail "idempotent re-run replaced the CLAUDE.md symlink"
  [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "idempotent re-run retargeted CLAUDE.md"
  pass "fm-ensure-agents-md.sh: existing CLAUDE.md symlink and AGENTS.md stay unchanged"
}

test_correct_symlink_is_left_in_place() {
  local repo agents out
  repo="$TMP_ROOT/symlink-keep-project"
  mkdir -p "$repo"
  printf '# Unique agent memory\n\nDo not clobber this payload.\n\n## Maintaining this file\n\nKeep this file for knowledge useful to almost every future agent session in this project.\nDo not repeat what the codebase already shows; point to the authoritative file or command instead.\nPrefer rewriting or pruning existing entries over appending new ones.\nWhen updating this file, preserve this bar for all agents and keep entries concise.\n' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for a correct CLAUDE.md symlink"
  assert_contains "$out" "unchanged:" "correct CLAUDE.md symlink was not left unchanged"
  assert_contains "$out" "kept existing CLAUDE.md symlink" "correct CLAUDE.md symlink was replaced"
  [ -L "$repo/CLAUDE.md" ] || fail "correct CLAUDE.md symlink was replaced with a regular file"
  [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "correct CLAUDE.md symlink was retargeted"
  cmp -s "$repo/.before" "$agents" \
    || fail "keeping the CLAUDE.md symlink clobbered AGENTS.md"
  assert_grep "Do not clobber this payload." "$agents" \
    "keeping the CLAUDE.md symlink lost unique AGENTS.md content"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on symlink re-run"
  assert_contains "$out" "unchanged:" "symlink re-run did not report unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "symlink re-run modified AGENTS.md"
  [ -L "$repo/CLAUDE.md" ] || fail "symlink re-run replaced CLAUDE.md"
  [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "symlink re-run retargeted CLAUDE.md"
  pass "fm-ensure-agents-md.sh: correct CLAUDE.md symlink stays a symlink"
}

test_existing_agents_md_without_claude_gains_pointer_only() {
  local repo agents out count
  repo="$TMP_ROOT/existing-bare-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md without CLAUDE.md"
  assert_contains "$out" "wrote:" "missing CLAUDE.md did not report a pointer write"
  assert_claude_pointer "$repo/CLAUDE.md"
  cmp -s "$repo/.before" "$agents" \
    || fail "writing a missing CLAUDE.md pointer modified AGENTS.md"
  assert_grep "Deploy with kubectl." "$agents" "existing AGENTS.md content was dropped"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 0 ] || fail "existing AGENTS.md gained $count self-governance sections"
  cp "$repo/CLAUDE.md" "$repo/.claude-after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on pointer re-run"
  assert_contains "$out" "unchanged:" "pointer re-run did not report unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "pointer re-run modified AGENTS.md"
  cmp -s "$repo/.claude-after-first" "$repo/CLAUDE.md" \
    || fail "pointer re-run modified CLAUDE.md"
  pass "fm-ensure-agents-md.sh: existing AGENTS.md without CLAUDE.md gains a pointer only"
}

test_existing_agents_md_with_section_reports_unchanged() {
  local repo agents out
  repo="$TMP_ROOT/fully-formed-project"
  mkdir -p "$repo"
  # Build a fully-formed project (AGENTS.md with the section + canonical pointer).
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed building the fully-formed fixture"
  agents="$repo/AGENTS.md"
  assert_claude_pointer "$repo/CLAUDE.md"
  cp "$agents" "$repo/.before"
  cp "$repo/CLAUDE.md" "$repo/.claude-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on already-formed project"
  assert_contains "$out" "unchanged:" "already-formed project was not reported unchanged"
  diff "$repo/.before" "$agents" >/dev/null \
    || fail "already-formed AGENTS.md was modified"
  cmp -s "$repo/.claude-before" "$repo/CLAUDE.md" \
    || fail "already-formed CLAUDE.md was modified"
  pass "fm-ensure-agents-md.sh: AGENTS.md that already has the section stays unchanged"
}

test_marked_project_guidance_stays_unchanged() {
  local repo eol route out
  for eol in $'\n' $'\r\n'; do
    for route in bare pointer symlink promotion; do
      repo=$(mktemp -d "$TMP_ROOT/marked-$route.XXXXXX")
      printf '%s%s' '<!-- firstmate:maintained-by-project -->' "$eol" \
        '# Project memory' "$eol" \
        '## Editing these notes' "$eol" \
        'Keep broadly useful knowledge concise; link to sources and rewrite stale entries.' "$eol" \
        'Preserve these rules for every agent.' "$eol" > "$repo/AGENTS.md"
      cp "$repo/AGENTS.md" "$repo/.before"
      case "$route" in
        pointer) write_fixture_claude_pointer "$repo" ;;
        symlink) ln -s AGENTS.md "$repo/CLAUDE.md" ;;
        promotion) mv "$repo/AGENTS.md" "$repo/CLAUDE.md" ;;
      esac
      "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
        || fail "ensure failed for marked project ($route)"
      cmp -s "$repo/.before" "$repo/AGENTS.md" \
        || fail "marked project guidance was modified ($route)"
      if [ "$route" = symlink ]; then
        [ -L "$repo/CLAUDE.md" ] || fail "marked project CLAUDE.md symlink was replaced"
        [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "marked project CLAUDE.md symlink was retargeted"
      else
        assert_claude_pointer "$repo/CLAUDE.md"
      fi
      out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
        || fail "ensure failed on marked project re-run ($route)"
      assert_contains "$out" "unchanged:" "marked project re-run did not report unchanged"
      cmp -s "$repo/.before" "$repo/AGENTS.md" \
        || fail "marked project re-run modified guidance ($route)"
      if [ "$route" = symlink ]; then
        [ -L "$repo/CLAUDE.md" ] || fail "marked project re-run replaced the CLAUDE.md symlink"
        [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "marked project re-run retargeted CLAUDE.md"
      else
        assert_claude_pointer "$repo/CLAUDE.md"
      fi
    done
  done
  pass "fm-ensure-agents-md.sh: marked project guidance is preserved across ensure paths and line endings"
}

test_existing_guidance_is_not_retrofitted() {
  local repo marker count eol line out
  for marker in '' 'Use <!-- firstmate:maintained-by-project --> here.' \
    '<!-- firstmate:maintained-by-project-extra -->' \
    $'```html\n<!-- firstmate:maintained-by-project -->\n```' \
    $'~~~html\n<!-- firstmate:maintained-by-project -->\n~~~' \
    '<!-- firstmate:maintained-by-project -->'; do
    for eol in $'\n' $'\r\n'; do
      repo=$(mktemp -d "$TMP_ROOT/reworded.XXXXXX")
      printf '%s\n' '# Project memory' "$marker" '## Editing these notes' \
        'Keep broadly useful knowledge concise; link to sources and rewrite stale entries.' \
        'Preserve these rules for every agent.' |
        while IFS= read -r line; do printf '%s%s' "$line" "$eol"; done > "$repo/AGENTS.md"
      cp "$repo/AGENTS.md" "$repo/.before"
      "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
        || fail "ensure failed for existing project guidance"
      cmp -s "$repo/.before" "$repo/AGENTS.md" \
        || fail "existing project guidance was retrofitted"
      assert_grep '## Editing these notes' "$repo/AGENTS.md" "ensure removed project guidance"
      count=$(grep -Fc '## Maintaining this file' "$repo/AGENTS.md")
      [ "$count" -eq 0 ] || fail "existing guidance gained the canonical section"
      assert_claude_pointer "$repo/CLAUDE.md"
      out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
        || fail "ensure failed on existing-guidance re-run"
      assert_contains "$out" "unchanged:" "existing-guidance re-run did not report unchanged"
      cmp -s "$repo/.before" "$repo/AGENTS.md" \
        || fail "existing-guidance re-run modified AGENTS.md"
    done
  done
  pass "fm-ensure-agents-md.sh: existing guidance is not retrofitted with the canonical section"
}

test_existing_crlf_agents_md_with_section_stays_unchanged() {
  local repo agents out count
  repo="$TMP_ROOT/crlf-formed-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/AGENTS.md"
  write_fixture_claude_pointer "$repo"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  cp "$repo/CLAUDE.md" "$repo/.claude-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on CRLF AGENTS.md with the section"
  assert_contains "$out" "unchanged:" "complete CRLF AGENTS.md was not reported unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "complete CRLF AGENTS.md was modified"
  cmp -s "$repo/.claude-before" "$repo/CLAUDE.md" \
    || fail "complete CRLF project's CLAUDE.md was modified"
  count=$(LC_ALL=C grep -a -c '## Maintaining this file' "$agents")
  [ "$count" -eq 1 ] || fail "complete CRLF AGENTS.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: CRLF AGENTS.md with the section stays unchanged"
}

test_existing_crlf_agents_md_without_section_stays_unchanged() {
  local repo agents out
  repo="$TMP_ROOT/crlf-untouched-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' > "$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for CRLF AGENTS.md without the section"
  assert_contains "$out" "unchanged:" "CRLF AGENTS.md with a CLAUDE.md symlink was not left unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "CRLF AGENTS.md without the section was modified"
  [ -L "$repo/CLAUDE.md" ] || fail "CRLF project's CLAUDE.md symlink was replaced"
  [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "CRLF project's CLAUDE.md symlink was retargeted"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on CRLF re-run"
  assert_contains "$out" "unchanged:" "CRLF re-run did not report unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "CRLF re-run modified AGENTS.md"
  [ -L "$repo/CLAUDE.md" ] || fail "CRLF re-run replaced the CLAUDE.md symlink"
  pass "fm-ensure-agents-md.sh: CRLF AGENTS.md without the section stays byte-identical"
}

test_canonical_pointer_is_accepted_when_both_are_real_files() {
  local repo out
  repo="$TMP_ROOT/both-real-pointer-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\n## Maintaining this file\n\nKeep this file for knowledge useful to almost every future agent session in this project.\nDo not repeat what the codebase already shows; point to the authoritative file or command instead.\nPrefer rewriting or pruning existing entries over appending new ones.\nWhen updating this file, preserve this bar for all agents and keep entries concise.\n' > "$repo/AGENTS.md"
  write_fixture_claude_pointer "$repo"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh refused a canonical real CLAUDE.md pointer"
  assert_contains "$out" "unchanged:" "canonical pointer plus AGENTS.md was not reported unchanged"
  assert_claude_pointer "$repo/CLAUDE.md"
  pass "fm-ensure-agents-md.sh: canonical real CLAUDE.md pointer is not a conflict"
}

test_distinct_real_files_are_refused() {
  local repo out rc
  repo="$TMP_ROOT/distinct-real-files-project"
  mkdir -p "$repo"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  printf '# Claude memory\n' > "$repo/CLAUDE.md"
  cp "$repo/AGENTS.md" "$repo/.agents-before"
  cp "$repo/CLAUDE.md" "$repo/.claude-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for distinct real AGENTS.md and CLAUDE.md"
  assert_contains "$out" "conflict:" "distinct real files did not report a conflict"
  cmp -s "$repo/.agents-before" "$repo/AGENTS.md" \
    || fail "distinct-real-files refusal modified AGENTS.md"
  cmp -s "$repo/.claude-before" "$repo/CLAUDE.md" \
    || fail "distinct-real-files refusal modified CLAUDE.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "distinct-real-files refusal turned CLAUDE.md into a symlink"
  pass "fm-ensure-agents-md.sh: refuses distinct real AGENTS.md and CLAUDE.md"
}

test_agents_md_symlink_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/agents-symlink-project"
  mkdir -p "$repo"
  printf '# payload\n' > "$repo/payload.md"
  ln -s payload.md "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when AGENTS.md is a symlink"
  assert_contains "$out" "conflict:" "AGENTS.md symlink did not report a conflict"
  [ -L "$repo/AGENTS.md" ] || fail "AGENTS.md symlink refusal disturbed the symlink"
  assert_absent "$repo/CLAUDE.md" "AGENTS.md symlink refusal created CLAUDE.md"
  pass "fm-ensure-agents-md.sh: refuses AGENTS.md when it is a symlink"
}

test_wrong_target_symlink_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/wrong-target-project"
  mkdir -p "$repo"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  printf '# other\n' > "$repo/OTHER.md"
  ln -s OTHER.md "$repo/CLAUDE.md"
  cp "$repo/AGENTS.md" "$repo/.agents-before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a CLAUDE.md symlink that does not point to AGENTS.md"
  assert_contains "$out" "conflict:" "wrong-target CLAUDE.md symlink did not report a conflict"
  [ -L "$repo/CLAUDE.md" ] || fail "wrong-target refusal removed the CLAUDE.md symlink"
  [ "$(readlink "$repo/CLAUDE.md")" = "OTHER.md" ] || fail "wrong-target refusal retargeted CLAUDE.md"
  cmp -s "$repo/.agents-before" "$repo/AGENTS.md" \
    || fail "wrong-target refusal modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: refuses a CLAUDE.md symlink that does not point to AGENTS.md"
}

test_non_regular_claude_md_is_refused() {
  local repo out rc
  repo="$TMP_ROOT/non-regular-claude-project"
  mkdir -p "$repo" "$repo/CLAUDE.md"
  printf '# Agents memory\n' > "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is a directory"
  assert_contains "$out" "conflict:" "non-regular CLAUDE.md did not report a conflict"
  [ -d "$repo/CLAUDE.md" ] || fail "non-regular CLAUDE.md refusal disturbed the directory"
  pass "fm-ensure-agents-md.sh: refuses a non-regular CLAUDE.md"
}

test_lowercase_agents_md_refuses_case_fragile_pointer() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/agents.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a lowercase agents.md"
  assert_contains "$out" "conflict:" "lowercase agents.md did not report a conflict"
  assert_contains "$out" "agents.md" "conflict message did not name the offending file"
  assert_absent "$repo/CLAUDE.md" "a case-fragile CLAUDE.md pointer was created for lowercase agents.md"
  [ ! -L "$repo/CLAUDE.md" ] || fail "a case-fragile CLAUDE.md symlink was created for lowercase agents.md"
  assert_present "$repo/agents.md" "the real lowercase agents.md was disturbed"
  pass "fm-ensure-agents-md.sh: refuses a case-variant lowercase agents.md (issue #389)"
}

test_dangling_correct_symlink_keeps_link_and_creates_skeleton() {
  local repo agents out count
  repo="$TMP_ROOT/dangling-symlink-project"
  mkdir -p "$repo"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for a dangling CLAUDE.md symlink"
  assert_contains "$out" "created:" "dangling CLAUDE.md symlink did not report a created AGENTS.md"
  assert_contains "$out" "kept CLAUDE.md symlink" "dangling CLAUDE.md symlink was replaced"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "dangling CLAUDE.md symlink did not gain AGENTS.md"
  assert_grep "## Maintaining this file" "$agents" "new skeleton omitted the self-governance section"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "new skeleton wrote $count self-governance sections"
  [ -L "$repo/CLAUDE.md" ] || fail "dangling CLAUDE.md symlink was replaced with a regular file"
  [ "$(readlink "$repo/CLAUDE.md")" = "AGENTS.md" ] || fail "dangling CLAUDE.md symlink was retargeted"
  cp "$agents" "$repo/.after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on dangling-symlink re-run"
  assert_contains "$out" "unchanged:" "dangling-symlink re-run did not report unchanged"
  cmp -s "$repo/.after-first" "$agents" \
    || fail "dangling-symlink re-run modified AGENTS.md"
  [ -L "$repo/CLAUDE.md" ] || fail "dangling-symlink re-run replaced CLAUDE.md"
  pass "fm-ensure-agents-md.sh: a correct dangling CLAUDE.md symlink stays a symlink"
}

test_created_agents_md_includes_self_governance
test_fresh_setup_writes_real_claude_pointer
test_promoted_claude_md_keeps_existing_content
test_promoted_claude_md_preserves_original_bytes
test_existing_agents_md_with_symlink_stays_put
test_correct_symlink_is_left_in_place
test_existing_agents_md_without_claude_gains_pointer_only
test_existing_agents_md_with_section_reports_unchanged
test_existing_crlf_agents_md_with_section_stays_unchanged
test_existing_crlf_agents_md_without_section_stays_unchanged
test_existing_guidance_is_not_retrofitted
test_marked_project_guidance_stays_unchanged
test_dangling_correct_symlink_keeps_link_and_creates_skeleton
test_canonical_pointer_is_accepted_when_both_are_real_files
test_distinct_real_files_are_refused
test_agents_md_symlink_is_refused
test_wrong_target_symlink_is_refused
test_non_regular_claude_md_is_refused
test_lowercase_agents_md_refuses_case_fragile_pointer
