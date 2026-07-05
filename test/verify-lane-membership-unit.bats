#!/usr/bin/env bats
# Lane-membership drop-guard (unit; no engine). UNIT_BATS/ACCEPT_BATS are hand lists in the Makefile
# and SECURITY/nightly are globs a rename can silently escape: a suite in NO lane never runs and CI
# stays green. Every top-level test/*.bats must belong to a lane, and this guard polices its own
# registration so it can't itself be dropped.
load test_helper/common

# one path per line from a (possibly backslash-continued) Makefile := assignment
_mk_list() {
  awk -v var="$1" '
    $0 ~ "^"var"[ \t]*:=" { sub(/^[^=]*=/, ""); invar=1 }
    invar { line=$0; cont=(line ~ /\\[ \t]*$/); sub(/\\[ \t]*$/, "", line)
            n=split(line, f, /[ \t]+/); for (i=1;i<=n;i++) if (f[i]!="") print f[i]
            if (!cont) invar=0 }' "$ROOT/Makefile"
}

@test "lanes: every hand-list entry exists on disk, and the parse is non-empty" {
  local n=0 f
  while IFS= read -r f; do
    n=$((n+1)); [ -f "$ROOT/$f" ] || { echo "UNIT_BATS lists a missing file: $f"; return 1; }
  done <<EOF
$(_mk_list UNIT_BATS)
EOF
  [ "$n" -ge 15 ] || { echo "UNIT_BATS parse suspiciously small ($n entries) - parser broken?"; return 1; }
  while IFS= read -r f; do
    [ -f "$ROOT/$f" ] || { echo "ACCEPT_BATS lists a missing file: $f"; return 1; }
  done <<EOF
$(_mk_list ACCEPT_BATS)
EOF
}

@test "lanes: every test/*.bats is in a lane (hand lists + security/nightly globs) - no orphans" {
  local lanes f rel orphans=""
  lanes="$(_mk_list UNIT_BATS; _mk_list ACCEPT_BATS)"
  for f in "$ROOT"/test/verify-security-*.bats "$ROOT"/test/nightly-*.bats; do
    lanes="$lanes
test/${f##*/}"
  done
  for f in "$ROOT"/test/*.bats; do
    rel="test/${f##*/}"
    printf '%s\n' "$lanes" | grep -qxF "$rel" || orphans="$orphans $rel"
  done
  [ -z "$orphans" ] || { echo "orphaned suite (in no Makefile lane):$orphans"; return 1; }
}

@test "lanes: this guard is itself registered in UNIT_BATS (self-registration)" {
  _mk_list UNIT_BATS | grep -qxF "test/verify-lane-membership-unit.bats"
}
