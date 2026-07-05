#!/usr/bin/env bats
# Bumped-lane upload controls host-side validation (unit; no engine). SLUICE_BUMP_METHODS /
# SLUICE_BUMP_MAX_BODY are sed'd into squid.conf in-box (the entrypoint re-validates too), so their
# charset is security-critical - a non-letter method token or a non-numeric body cap must die host-side.
# The in-box squid ACL wiring is exercised by acceptance-bump.bats on a real box.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  SLUICE_BIN="${src%/src}/bin/sluice"
}

_run_validate_bump() {  # $1 = SLUICE_BUMP_METHODS, $2 = SLUICE_BUMP_MAX_BODY
  local t="$BATS_TEST_TMPDIR/vb.sh"
  {
    echo 'set -euo pipefail'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    sed -n '/^validate_bump_controls()/,/^}/p' "$SLUICE_BIN"
    echo 'validate_bump_controls'
  } > "$t"
  SLUICE_BUMP_METHODS="${1:-}" SLUICE_BUMP_MAX_BODY="${2:-}" run bash "$t"
}

@test "bump validate: a method token with non-letters dies (sed-injection guard)" {
  _run_validate_bump 'GET;rm' ''
  assert_failure
  assert_output --partial "letters only"
}
@test "bump validate: a clean method allowlist passes" { _run_validate_bump 'GET HEAD OPTIONS' ''; assert_success; }
@test "bump validate: a non-numeric max-body dies" {
  _run_validate_bump '' 'big'
  assert_failure
  assert_output --partial "byte count"
}
@test "bump validate: a numeric max-body passes" { _run_validate_bump 'POST' '1048576'; assert_success; }
@test "bump validate: both unset is a no-op pass" { _run_validate_bump '' ''; assert_success; }

# The launcher passes the knobs to the box via -e SLUICE_RUNTIME_BUMP_METHODS/_MAX_BODY (structural).
@test "bump: the run path forwards the bump-control knobs into the box" {
  run grep -q 'SLUICE_RUNTIME_BUMP_METHODS=' "$SLUICE_BIN"
  assert_success
  run grep -q 'SLUICE_RUNTIME_BUMP_MAX_BODY=' "$SLUICE_BIN"
  assert_success
}
