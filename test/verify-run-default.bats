#!/usr/bin/env bats
# Bare `sluice` (run-default) must propagate SLUICE_RUN_CMD's exit status. Regression: the trailing
# no-op / overlay / onboarding hints reset $? to 0, so `sluice` exited 0 even when the configured
# command failed - a false green in CI, Makefiles, and `sluice && deploy`. Build the box once, then
# assert a failing run-cmd surfaces its code. (`sluice run <cmd>` always propagated; this is run-default.)
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/p"
  printf 'SLUICE_NAME="rundefault"\nSLUICE_RUN_CMD="exit 7"\n' > "$WORK/p/sluice.config.sh"
  ( cd "$WORK/p" && SLUICE_NO_BANNER=1 "$SLUICE" build ) >/dev/null 2>&1 || true
}

teardown_file() { drop_box sluice-rundefault "$WORK/p"; }

@test "run-default: bare sluice propagates SLUICE_RUN_CMD's exit status (exit 7 -> 7)" {
  cd "$WORK/p"
  run env SLUICE_NO_BANNER=1 "$SLUICE"
  [ "$status" -eq 7 ]
}
