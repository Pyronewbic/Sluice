#!/usr/bin/env bats
# write_lock fail-closed (unit; no engine). current_inventory's in-image read is masked by a `sort -u`
# pipe and consumed via a command substitution, so a failed engine read can't trip set -e - it returns
# the base ref ONLY. write_lock must refuse to overwrite ./sluice.lock with that hollow inventory (a
# base-only artifact reported as success, then --check flags every real package as drift). A real Wolfi
# box always carries apks, so write_lock asserts at least one apk line before writing, else dies.
# Extracts write_lock from the built launcher and runs it under the real set -euo pipefail (the way the
# launcher executes), with current_inventory stubbed and the lock path pointed at a temp file.
load test_helper/common

# Build a self-contained script: stubs + the extracted write_lock + an invocation, run under the
# launcher's shell options. $1 = the body of the current_inventory stub (what the image read returns).
_run_write_lock() {
  local t="$BATS_TEST_TMPDIR/write_lock.sh"
  {
    echo 'set -euo pipefail'
    printf 'PROJECT_DIR=%q\n' "$BATS_TEST_TMPDIR"
    echo 'tag="sluice-locktest:latest"'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    echo '_tilde() { printf "%s" "$1"; }'
    echo 'C_GRN=""; C_RED=""; C_YEL=""; C_RST=""; E_GRN=""; E_RED=""; E_YEL=""; E_RST=""'
    echo 'maybe_build() { :; }'                                  # no engine in the unit lane
    echo 'classify_drift() { :; }; lock_drift() { :; }; render_drift_human() { :; }'   # delta path (only fires if a lock pre-exists)
    printf 'current_inventory() { cat <<%s\n' "EOF_INV"
    printf '%s\n' "$1"
    echo 'EOF_INV'
    echo '}'
    sed -n '/^write_lock()/,/^}/p' "$ROOT/bin/sluice"
    echo 'write_lock'
  } > "$t"
  run bash "$t"
}

@test "write-lock: a base-only inventory (engine read failed) refuses to write a hollow sluice.lock" {
  _run_write_lock "base  cgr.dev/chainguard/wolfi-base@sha256:deadbeef"
  assert_failure
  assert_output --partial "hollow sluice.lock"
  refute [ -f "$BATS_TEST_TMPDIR/sluice.lock" ]   # nothing written
}

@test "write-lock: a base + apk inventory writes the lock and exits 0" {
  _run_write_lock "$(printf 'base  cgr.dev/chainguard/wolfi-base@sha256:deadbeef\napk  busybox 1.36.1 Q1xxx\napk  ca-certificates-bundle 20240705 Q1yyy')"
  assert_success
  assert [ -f "$BATS_TEST_TMPDIR/sluice.lock" ]
  assert_output --partial "2 apk"
  run cat "$BATS_TEST_TMPDIR/sluice.lock"
  assert_output --partial "apk  busybox"
}
