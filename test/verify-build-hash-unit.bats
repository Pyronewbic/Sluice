#!/usr/bin/env bats
# build() must NOT mask a config_hash failure. `local args=(--label ...$(config_hash)...)` returns
# local's own 0 status, so a failing hash (e.g. shasum rc 127) would bake an EMPTY sluice.confighash
# label under set -e - after which every maybe_build sees a mismatch and rebuilds silently. Hoisted onto
# its own assignment, the failure propagates and the build dies. (unit; no engine.)
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  BIN="${src%/src}/bin/sluice"   # capture before sourcing: the prelude re-derives ROOT from $0
  SRC="$src"
}

@test "build-hash: a failing config_hash aborts the build under set -e (no empty-label bake)" {
  local core; core="$(mktemp -d)"; : > "$core/Dockerfile"
  local pdir; pdir="$(mktemp -d)"; : > "$pdir/sluice.config.sh"
  # Run in a fresh set -e shell (bats `run` disables errexit, which is the very thing under test).
  run bash -euo pipefail -c '
    . "'"$SRC"'/00-prelude.sh"; . "'"$SRC"'/70-build-run.sh"
    config_hash() { return 127; }        # simulate shasum missing / a broken hash
    CORE="'"$core"'"; PROJECT_DIR="'"$pdir"'"; PROJECT_CONFIG="'"$pdir"'/sluice.config.sh"
    build
  '
  assert_failure
  rm -rf "$core" "$pdir"
}

@test "build-hash: the confighash is hoisted, not masked in the local array (structural)" {
  local body; body="$(sed -n '/^build()/,/^}/p' "$BIN")"
  printf '%s\n' "$body" | grep -qF '_chash="$(config_hash)"'                                  # hoisted onto its own assignment
  ! printf '%s\n' "$body" | grep -qF 'local args=(--label "sluice.confighash=$(config_hash)"' # not inline (masked) in the array
}
