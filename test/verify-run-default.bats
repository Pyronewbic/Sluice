#!/usr/bin/env bats
# Bare `sluice` (run-default) must propagate SLUICE_RUN_CMD's exit status. Regression: the trailing
# no-op / overlay / onboarding hints reset $? to 0, so `sluice` exited 0 even when the configured
# command failed - a false green in CI, Makefiles, and `sluice && deploy`. Build the box once, then
# assert a failing run-cmd surfaces its code. (`sluice run <cmd>` always propagated; this is run-default.)
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/p" "$WORK/m"
  printf 'SLUICE_NAME="rundefault"\nSLUICE_RUN_CMD="exit 7"\n' > "$WORK/p/sluice.config.sh"
  cat > "$WORK/m/sluice.config.sh" <<'CFG'
SLUICE_NAME="runmulti"
SLUICE_RUN_CMD='
echo one
echo two
echo three
'
CFG
  ( cd "$WORK/p" && SLUICE_NO_BANNER=1 "$SLUICE" build ) >/dev/null 2>&1 || true
  ( cd "$WORK/m" && SLUICE_NO_BANNER=1 "$SLUICE" build ) >/dev/null 2>&1 || true
}

teardown_file() { drop_box sluice-rundefault "$WORK/p"; drop_box sluice-runmulti "$WORK/m"; }

@test "run-default: bare sluice propagates SLUICE_RUN_CMD's exit status (exit 7 -> 7)" {
  cd "$WORK/p"
  run env SLUICE_NO_BANNER=1 "$SLUICE"
  [ "$status" -eq 7 ]
}

@test "run-default: a multi-line SLUICE_RUN_CMD is summarized in the run line, not dumped" {
  cd "$WORK/m"
  run env SLUICE_NO_BANNER=1 "$SLUICE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"running: a 3-line command"* ]]   # the body is summarized, not dumped verbatim
  [[ "$output" == *one* && "$output" == *three* ]]    # ...and the body still actually ran
}
