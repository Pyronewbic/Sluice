#!/usr/bin/env bats
# config_hash rebuild trigger: editing a HASHED field (SLUICE_DESC) changes the image's confighash
# label; editing SLUICE_ALLOW_DOMAINS (a runtime override) does NOT. Build-only (no running box).
# Ported from verify-security.sh.
load test_helper/common

_hashlabel() { "$ENG" image inspect -f '{{ index .Config.Labels "sluice.confighash" }}' sluice-sectest-hash 2>/dev/null; }

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/h"
  printf 'SLUICE_NAME="sectest-hash"\nSLUICE_DESC="one"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/h/sluice.config.sh"
  ( cd "$WORK/h" && "$SLUICE" build ) >/dev/null 2>&1 || true; _hashlabel > "$WORK/h1"
  printf 'SLUICE_NAME="sectest-hash"\nSLUICE_DESC="two"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/h/sluice.config.sh"
  ( cd "$WORK/h" && "$SLUICE" build ) >/dev/null 2>&1 || true; _hashlabel > "$WORK/h2"
  printf 'SLUICE_NAME="sectest-hash"\nSLUICE_DESC="two"\nSLUICE_ALLOW_DOMAINS="example.org"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/h/sluice.config.sh"
  ( cd "$WORK/h" && "$SLUICE" build ) >/dev/null 2>&1 || true; _hashlabel > "$WORK/h3"
}

teardown_file() {
  "$ENG" rmi -f sluice-sectest-hash >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "config-hash: initial build recorded a non-empty confighash label" {
  [ -n "$(cat "$WORK/h1")" ]
}

@test "config-hash: editing a hashed field (SLUICE_DESC) changed the hash" {
  [ "$(cat "$WORK/h1")" != "$(cat "$WORK/h2")" ]
}

@test "config-hash: SLUICE_ALLOW_DOMAINS edit did NOT change the hash (runtime override)" {
  [ "$(cat "$WORK/h2")" = "$(cat "$WORK/h3")" ]
}
