#!/usr/bin/env bats
# Replay manifest write_pin (unit; no engine). `sluice lock --pin` writes a committable sluice.pin -
# the base pinned by @sha256 digest plus every apk/npm/pip/gem/go/cargo name+version - for a
# SLUICE_PIN=1 replay build (M2). It fails CLOSED two ways: a hollow inventory (the masked-read case,
# like write_lock) and a base that cannot be resolved to a digest (a pin that can't freeze its base is
# worse than none). It also refreshes sluice.lock in the same pass so the two never disagree. This
# suite extracts write_pin from the built launcher (the verify-lock-unit pattern), stubs _pin_inventory
# with a fixture + write_lock, and runs it under the launcher's real set -euo pipefail. The strict flag
# parse is checked through the dispatch, before any build.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  SLUICE_BIN="${src%/src}/bin/sluice"
}

# Build a self-contained script: stubs + the extracted write_pin + an invocation. $1 = the fixture the
# _pin_inventory stub emits (the digest-checked base line + package lines).
_run_write_pin() {
  local t="$BATS_TEST_TMPDIR/write_pin.sh"
  {
    echo 'set -euo pipefail'
    printf 'PROJECT_DIR=%q\n' "$BATS_TEST_TMPDIR"
    echo 'tag="sluice-pintest:latest"'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    echo 'maybe_build() { :; }'
    echo 'write_lock() { echo "[sluice] wrote lock (stub)"; : > "$PROJECT_DIR/sluice.lock"; }'
    printf '_pin_inventory() { cat <<%s\n' "EOF_INV"
    printf '%s\n' "$1"
    echo 'EOF_INV'
    echo '}'
    sed -n '/^write_pin()/,/^}/p' "$SLUICE_BIN"
    echo 'write_pin'
  } > "$t"
  run bash "$t"
}

@test "write-pin: an apk-less inventory refuses to write a hollow sluice.pin" {
  _run_write_pin "base  cgr.dev/chainguard/wolfi-base@sha256:deadbeef"
  assert_failure
  assert_output --partial "hollow sluice.pin"
  refute [ -f "$BATS_TEST_TMPDIR/sluice.pin" ]
}

@test "write-pin: a base without an @sha256 digest refuses (a pin must freeze its base)" {
  _run_write_pin "$(printf 'base  cgr.dev/chainguard/wolfi-base\napk  busybox 1.36.1 Q1x')"
  assert_failure
  assert_output --partial "base image digest"
  refute [ -f "$BATS_TEST_TMPDIR/sluice.pin" ]
}

@test "write-pin: a digest-pinned inventory writes sluice.pin and refreshes sluice.lock" {
  _run_write_pin "$(printf 'base  cgr.dev/chainguard/wolfi-base@sha256:abc123\napk  busybox 1.36.1 Q1x\nnpm  left-pad 1.3.0\npip  requests 2.31.0')"
  assert_success
  assert [ -f "$BATS_TEST_TMPDIR/sluice.pin" ]
  assert [ -f "$BATS_TEST_TMPDIR/sluice.lock" ]   # --pin also refreshed the lock (single pass, one image)
  run cat "$BATS_TEST_TMPDIR/sluice.pin"
  assert_output --partial "base  cgr.dev/chainguard/wolfi-base@sha256:abc123"
  assert_output --partial "apk  busybox 1.36.1"
  assert_output --partial "npm  left-pad 1.3.0"
  assert_output --partial "pip  requests 2.31.0"
}

@test "write-pin: package lines are sorted for a stable diff" {
  _run_write_pin "$(printf 'base  x@sha256:abc\napk  zlib 1.3\napk  busybox 1.36.1 Q1x\nnpm  aaa 1.0')"
  assert_success
  # the three non-base lines come out LC_ALL=C sorted: apk busybox < apk zlib < npm aaa
  run cat "$BATS_TEST_TMPDIR/sluice.pin"
  local body; body="$(grep -vE '^#|^base ' "$BATS_TEST_TMPDIR/sluice.pin")"
  [ "$(printf '%s\n' "$body" | sed -n '1p')" = "apk  busybox 1.36.1 Q1x" ]
  [ "$(printf '%s\n' "$body" | sed -n '3p')" = "npm  aaa 1.0" ]
}

# --- strict flag parse via the dispatch (no build): an extra arg dies before write_pin ------------
@test "lock --pin: an extra arg is rejected (strict parse), before any build" {
  printf 'SLUICE_RUN_CMD="true"\n' > "$BATS_TEST_TMPDIR/sluice.config.sh"
  run bash -c "cd '$BATS_TEST_TMPDIR' && SLUICE_ENGINE=true '$SLUICE_BIN' lock --pin --bogus"
  assert_failure
  assert_output --partial "usage: sluice lock --pin"
}
