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


# --- coverage gaps surfaced by the test-case review (changed-behavior edge/bad paths) ---
@test "prelaunch: a hook-exported SLUICE_ENV value reaches the box, re-minted across a rebuild" {
  mkdir -p "$WORK/pre-env"
  # The hook mints a fresh token each invocation and logs it OUTSIDE the project dir (the box chowns
  # the mount to uid 1000 on Linux, so a host append inside $WORK/pre-env would EACCES after run one).
  cat > "$WORK/pre-env/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-preenv"
SLUICE_RUN_CMD="bash"
SLUICE_ENV="PRE_TOKEN"
mint() { export PRE_TOKEN="tok-\${RANDOM}\${RANDOM}"; printf '%s\n' "\$PRE_TOKEN" >> "$WORK/preenv-mint"; }
SLUICE_PRELAUNCH="mint"
CFG
  run bash -c "cd '$WORK/pre-env' && '$SLUICE' run sh -c 'echo BOX=\$PRE_TOKEN' 2>/dev/null"
  box1="$(printf '%s\n' "$output" | sed -n 's/^BOX=//p')"
  mint1="$(tail -n1 "$WORK/preenv-mint" 2>/dev/null)"
  [ -n "$box1" ]
  [ "$box1" = "$mint1" ]                 # the hook's freshly-exported value was forwarded into the box
  ( cd "$WORK/pre-env" && "$SLUICE" rebuild ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/pre-env' && '$SLUICE' run sh -c 'echo BOX=\$PRE_TOKEN' 2>/dev/null"
  box2="$(printf '%s\n' "$output" | sed -n 's/^BOX=//p')"
  mint2="$(tail -n1 "$WORK/preenv-mint" 2>/dev/null)"
  [ "$box2" = "$mint2" ]                 # re-minted value forwarded after the box was rebuilt
  [ "$box2" != "$box1" ]                 # a genuinely fresh credential, not the creation-time one
  destroy_box preenv pre-env
}
