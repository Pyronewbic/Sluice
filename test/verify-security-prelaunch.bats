#!/usr/bin/env bats
# SLUICE_PRELAUNCH host hook: a function value runs host-side before EVERY session (warm boxes
# included, so short-lived creds re-mint); a non-function value is rejected before any docker run.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/pre"
  # Marker lives OUTSIDE the project dir: the box chowns the mount to uid 1000 on Linux, so a
  # host-side append into $WORK/pre would EACCES after the first run. $WORK stays host-owned.
  cat > "$WORK/pre/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-pre"
SLUICE_RUN_CMD="bash"
stage_marker() { echo "ran" >> "$WORK/prelaunch-ran"; }
SLUICE_PRELAUNCH="stage_marker"
CFG
  ( cd "$WORK/pre" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() { destroy_box pre pre; }

@test "prelaunch: a host-side function hook ran (marker created)" {
  [ -f "$WORK/prelaunch-ran" ]
}

@test "prelaunch: the hook fires again for a session into an already-running box" {
  [ -f "$WORK/prelaunch-ran" ] || skip "cold-start hook run missing"
  before="$(grep -c . "$WORK/prelaunch-ran")"
  ( cd "$WORK/pre" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  after="$(grep -c . "$WORK/prelaunch-ran")"
  [ "$after" -gt "$before" ]
}

@test "prelaunch: the hook fires once per invocation, not once per phase" {
  # A cold start passes ensure_up AND start(); the done-guard must collapse that to one firing.
  : > "$WORK/prelaunch-ran"
  ( cd "$WORK/pre" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  ( cd "$WORK/pre" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  [ "$(grep -c . "$WORK/prelaunch-ran")" -eq 1 ]
}

@test "prelaunch: a non-function value is rejected (die before docker run)" {
  # FRESH dir - after the run above the entrypoint chowned $WORK/pre to uid 1000 on Linux, so a
  # rewrite there would EACCES; the rejection is host-side so the dir's image is moot.
  mkdir -p "$WORK/pre-bad"
  printf 'SLUICE_NAME="sectest-pre"\nSLUICE_RUN_CMD="bash"\nSLUICE_PRELAUNCH="definitely_not_a_function_xyz"\n' > "$WORK/pre-bad/sluice.config.sh"
  run bash -c "cd '$WORK/pre-bad' && '$SLUICE' run true"
  assert_failure
}
