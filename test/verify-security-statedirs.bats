#!/usr/bin/env bats
# SLUICE_STATE_DIRS: a persisted dir survives container recreation and lives in a host store OUTSIDE
# the project tree; an absolute / .. entry is rejected. Ported from verify-security.sh.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/state"
  export STORE; STORE="${XDG_STATE_HOME:-$HOME/.local/state}/sluice/sectest-state"   # host-side, outside the temp tree
  printf 'SLUICE_NAME="sectest-state"\nSLUICE_STATE_DIRS=".cache"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/state/sluice.config.sh"
  ( cd "$WORK/state" && "$SLUICE" run sh -c 'echo persisted-ok > "$HOME/.cache/marker.txt"' ) >/dev/null 2>&1 || true
  ( cd "$WORK/state" && "$SLUICE" stop ) >/dev/null 2>&1 || true   # remove the container
  ( cd "$WORK/state" && "$SLUICE" run true ) >/dev/null 2>&1 || true   # recreate it cleanly
}

teardown_file() {
  chown_back_tree sluice-sectest-state "$WORK"
  chown_back_tree sluice-sectest-state "$STORE"
  ( cd "$WORK/state" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-state >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-state >/dev/null 2>&1 || true
  rm -rf "$WORK" "$STORE"
}

@test "state-dirs: the file survived container recreation" {
  run bash -c "cd '$WORK/state' && '$SLUICE' run cat /home/sluice/.cache/marker.txt 2>/dev/null"
  assert_output "persisted-ok"
}

@test "state-dirs: the host store lives outside the project tree" {
  [ -f "$STORE/.cache/marker.txt" ]
}

@test "state-dirs: an absolute path is rejected (die)" {
  mkdir -p "$WORK/state-bad"
  printf 'SLUICE_NAME="sectest-state"\nSLUICE_STATE_DIRS="/etc"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/state-bad/sluice.config.sh"
  run bash -c "cd '$WORK/state-bad' && '$SLUICE' run true"
  assert_failure
}
