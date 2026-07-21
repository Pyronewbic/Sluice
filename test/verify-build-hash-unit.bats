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

# The test above stubs config_hash, so it proves build() propagates a failure - it CANNOT prove
# config_hash actually fails when the hasher does. That gap let a regression through: _sha256 was
# rewritten to end in `printf` instead of a pipeline, so a broken/missing hasher returned 0 with EMPTY
# output. config_hash then yielded "", and every freshness gate compares `[ "$label" = "$(config_hash)" ]`
# -> "" = "" -> forever fresh, so a box with a stale firewall/seccomp would never rebuild. Stub the
# HASHER (PATH-shadow both tools), never config_hash, and assert the failure actually propagates.
@test "build-hash: _sha256 fails closed when the hasher is broken (not empty output, rc 0)" {
  local shim; shim="$(mktemp -d)"
  printf '#!/bin/sh\nexit 2\n' > "$shim/sha256sum"; printf '#!/bin/sh\nexit 2\n' > "$shim/shasum"
  chmod +x "$shim/sha256sum" "$shim/shasum"
  # _sha256 must be the LAST command so bash -c exits with its status (a trailing echo would mask it).
  run env PATH="$shim:$PATH" bash -c '. "'"$SRC"'/00-prelude.sh"; . "'"$SRC"'/10-egress-helpers.sh"; printf x | _sha256'
  assert_failure                                   # must NOT exit 0
  assert_output ""                                 # and must not emit an empty "digest"
  rm -rf "$shim"
}

@test "build-hash: a broken hasher kills config_hash under set -e, so no empty label is baked" {
  local shim pdir core; shim="$(mktemp -d)"; pdir="$(mktemp -d)"; core="$(mktemp -d)"
  printf '#!/bin/sh\nexit 2\n' > "$shim/sha256sum"; printf '#!/bin/sh\nexit 2\n' > "$shim/shasum"
  chmod +x "$shim/sha256sum" "$shim/shasum"
  : > "$pdir/sluice.config.sh"; : > "$core/Dockerfile"
  run env PATH="$shim:$PATH" bash -euo pipefail -c '
    . "'"$SRC"'/00-prelude.sh"; . "'"$SRC"'/10-egress-helpers.sh"
    PROJECT_CONFIG="'"$pdir"'/sluice.config.sh"; CORE="'"$core"'"; PROJECT_DIR="'"$pdir"'"
    _c="$(config_hash)"; printf "SURVIVED label=[%s]\n" "$_c"'
  assert_failure                                   # config_hash must abort, not return ""
  refute_output --partial "SURVIVED"
  rm -rf "$shim" "$pdir" "$core"
}

