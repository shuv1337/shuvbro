#!/usr/bin/env bash
# Drive the executable fork-boundary check as a public interface, including
# negative scratch copies. Never mutates the real source tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-fork-boundary-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-boundary)

out=$("$CHECK") || fail "fork-boundary check failed"
printf '%s\n' "$out" | grep -qx 'fm-fork-boundary-check: ok' \
  || fail "fork-boundary check did not report ok"
pass "fork-boundary check passes"

scratch_tree() {
  local dest=$1 file dir
  mkdir -p "$dest"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    dir=$(dirname "$file")
    mkdir -p "$dest/$dir"
    cp -a "$ROOT/$file" "$dest/$file"
  done < <(git -C "$ROOT" ls-files)
  git -C "$dest" init -q
  git -C "$dest" add -A
  git -C "$dest" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm scratch
}

test_negative_upstream_clone_url() {
  local dest err
  dest="$TMP_ROOT/upstream-clone"
  scratch_tree "$dest"
  printf '\ngit clone https://github.com/kunchenguid/firstmate\n' >> "$dest/README.md"
  err="$TMP_ROOT/upstream.err"
  if "$CHECK" --root "$dest" >/dev/null 2>"$err"; then
    fail "check accepted an upstream clone URL in a scratch README"
  fi
  grep -q 'still installs from upstream clone URL' "$err" \
    || fail "scratch upstream clone did not fail the clone-URL assertion"
  pass "scratch upstream clone URL is refused"
}

test_negative_mandatory_captain_address() {
  local dest err
  dest="$TMP_ROOT/captain-addr"
  scratch_tree "$dest"
  printf '\nAddress the user as "captain" at least once in every response.\n' >> "$dest/AGENTS.md"
  err="$TMP_ROOT/captain.err"
  if "$CHECK" --root "$dest" >/dev/null 2>"$err"; then
    fail "check accepted mandatory captain address in a scratch AGENTS.md"
  fi
  grep -q 'mandates captain address' "$err" \
    || fail "scratch captain address did not fail the loaded-instruction assertion"
  pass "scratch mandatory captain address is refused"
}

test_negative_firstmate_op_mutation() {
  local dest err
  dest="$TMP_ROOT/op-mut"
  scratch_tree "$dest"
  python3 - "$dest/bin/fm-operational-input.sh" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
p.write_text(text.replace("FIRSTMATE_OP:", "SHUVBRO_OP:"))
PY
  err="$TMP_ROOT/op.err"
  if "$CHECK" --root "$dest" >/dev/null 2>"$err"; then
    fail "check accepted a mutated FIRSTMATE_OP prefix"
  fi
  grep -q 'FIRSTMATE_OP' "$err" \
    || fail "mutated FIRSTMATE_OP did not fail the compatibility assertion"
  pass "scratch FIRSTMATE_OP mutation is refused"
}

test_negative_tracked_private_config() {
  local dest err
  dest="$TMP_ROOT/priv-config"
  scratch_tree "$dest"
  mkdir -p "$dest/config"
  printf 'preset=bro\n' > "$dest/config/persona"
  git -C "$dest" add -f config/persona
  git -C "$dest" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm 'track private config'
  err="$TMP_ROOT/priv.err"
  if "$CHECK" --root "$dest" >/dev/null 2>"$err"; then
    fail "check accepted tracked private config/"
  fi
  grep -q 'private fleet paths are tracked' "$err" \
    || fail "tracked config/persona did not fail the private-path assertion"
  pass "scratch tracked private config is refused"
}

test_negative_skill_mandatory_captain_address() {
  local dest err
  dest="$TMP_ROOT/skill-addr"
  scratch_tree "$dest"
  printf '\nAddress the user as "captain" at least once in every response.\n' \
    >> "$dest/.agents/skills/ahoy/SKILL.md"
  err="$TMP_ROOT/skill.err"
  if "$CHECK" --root "$dest" >/dev/null 2>"$err"; then
    fail "check accepted mandatory captain address in a scratch skill"
  fi
  grep -q 'mandates captain address' "$err" \
    || fail "scratch skill captain address did not fail the loaded-instruction assertion"
  pass "scratch skill mandatory captain address is refused"
}

test_negative_new_doc_reintroduces_product() {
  local dest err
  dest="$TMP_ROOT/new-doc"
  scratch_tree "$dest"
  printf '%s\n' '# New' 'Address the user as "captain" at least once in every response.' \
    'git clone https://github.com/kunchenguid/firstmate' \
    > "$dest/docs/new-product.md"
  git -C "$dest" add docs/new-product.md
  git -C "$dest" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm 'add new doc'
  err="$TMP_ROOT/newdoc.err"
  if "$CHECK" --root "$dest" >/dev/null 2>"$err"; then
    fail "check accepted a new doc reintroducing upstream identity"
  fi
  grep -q 'mandates captain address\|upstream clone URL' "$err" \
    || fail "scratch new doc did not fail the docs identity assertion"
  pass "scratch new doc reintroducing firstmate product identity is refused"
}

test_negative_upstream_clone_url
test_negative_mandatory_captain_address
test_negative_skill_mandatory_captain_address
test_negative_new_doc_reintroduces_product
test_negative_firstmate_op_mutation
test_negative_tracked_private_config
