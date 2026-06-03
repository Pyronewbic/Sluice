#!/usr/bin/env bats
# SLUICE_PRELAUNCH host hook: a function value runs host-side before launch; a non-function value is
# rejected in start() before any docker run. Ported from verify-security.sh.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/pre"
  cat > "$WORK/pre/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-pre"
SLUICE_RUN_CMD="bash"
stage_marker() { touch "$WORK/pre/prelaunch-ran"; }
SLUICE_PRELAUNCH="stage_marker"
CFG
  ( cd "$WORK/pre" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  chown_back_tree sluice-sectest-pre "$WORK"
  ( cd "$WORK/pre" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-pre >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-pre >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "prelaunch: a host-side function hook ran (marker created)" {
  [ -f "$WORK/pre/prelaunch-ran" ]
}

@test "prelaunch: a non-function value is rejected (die before docker run)" {
  # FRESH dir - after the run above the entrypoint chowned $WORK/pre to uid 1000 on Linux, so a
  # rewrite there would EACCES; the rejection is host-side in start() so the dir's image is moot.
  mkdir -p "$WORK/pre-bad"
  printf 'SLUICE_NAME="sectest-pre"\nSLUICE_RUN_CMD="bash"\nSLUICE_PRELAUNCH="definitely_not_a_function_xyz"\n' > "$WORK/pre-bad/sluice.config.sh"
  run bash -c "cd '$WORK/pre-bad' && '$SLUICE' run true"
  assert_failure
}
