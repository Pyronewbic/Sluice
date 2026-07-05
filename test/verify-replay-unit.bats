#!/usr/bin/env bats
# Pinned-replay build helper core/replay.sh (unit; no engine). Baked as /usr/local/bin/sluice-replay and
# run in the Dockerfile's guarded pin legs, it converges installed versions onto sluice.pin. We can't run
# a real build here, but replay.sh is POSIX sh, so copy it with the PIN path redirected at a temp file,
# stub the package managers on PATH, and assert: it no-ops unless SLUICE_PIN=1, fails closed when the pin
# is missing, and emits the exact per-ecosystem install coordinates per phase. The end-to-end pinned
# build + inventory verification is a nightly-lock case.
load test_helper/common

_run_replay() {  # $1 = phase, $2 = SLUICE_PIN value, $3 = pin file contents ("" = no file)
  local rp="$BATS_TEST_TMPDIR/replay.sh" pin="$BATS_TEST_TMPDIR/sluice.pin" bin="$BATS_TEST_TMPDIR/bin"
  sed "s#^PIN=.*#PIN=$pin#" "$ROOT/core/replay.sh" > "$rp"
  if [ -n "${3:-}" ]; then printf '%s\n' "$3" > "$pin"; else rm -f "$pin"; fi
  mkdir -p "$bin"
  local t
  for t in apk npm gem pip go cargo; do printf '#!/bin/sh\necho "%s $*"\n' "$t" > "$bin/$t"; chmod +x "$bin/$t"; done
  SLUICE_PIN="${2:-}" PATH="$bin:$PATH" run sh "$rp" "$1"
}

@test "replay: no-op (exit 0) when SLUICE_PIN is not 1" {
  _run_replay root "" "apk  busybox  1.36.1  Q1x"
  assert_success
  refute_output --partial "apk add"
}

@test "replay: SLUICE_PIN=1 with a missing pin fails closed" {
  _run_replay root 1 ""
  assert_failure
  assert_output --partial "missing or empty"
}

@test "replay root: installs the pinned apk + npm + gem coordinates" {
  _run_replay root 1 "$(printf 'base  x@sha256:a\napk  busybox  1.36.1  Q1x\nnpm  left-pad  1.3.0\ngem  rake  13.0.6')"
  assert_success
  assert_output --partial "apk add --no-cache busybox=1.36.1"
  assert_output --partial "npm install -g left-pad@1.3.0"
  assert_output --partial "gem install --conservative rake -v 13.0.6"
}

@test "replay user: installs pip/go/cargo coordinates, never touches apk" {
  _run_replay user 1 "$(printf 'base  x@sha256:a\napk  busybox  1.36.1  Q1x\npip  requests  2.31.0\ngo  rsc.io/2fa  v1.2.0\ncargo  ripgrep  14.1.1')"
  assert_success
  assert_output --partial "requests==2.31.0"
  assert_output --partial "go install rsc.io/2fa@v1.2.0"
  assert_output --partial "cargo install ripgrep --version 14.1.1 --locked"
  refute_output --partial "apk add"
}

@test "replay: comment + base lines are ignored (no bogus install)" {
  _run_replay root 1 "$(printf '# sluice.pin header\nbase  x@sha256:a\napk  busybox  1.36.1  Q1x')"
  assert_success
  refute_output --partial "sluice.pin"
  refute_output --partial "add --no-cache header"
}
