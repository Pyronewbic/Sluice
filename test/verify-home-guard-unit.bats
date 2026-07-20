#!/usr/bin/env bats
# Mount-scope guard: the box bind-mounts PROJECT_DIR (the dir of the found sluice.config.sh) read-write,
# so launched from $HOME / / it would mount the whole home tree into the sandbox. The guard runs at
# session start, BEFORE any engine call, so these are fast + Docker-free: SLUICE_ENGINE=false makes the
# (irrelevant) build fail instantly while we assert on the guard's own stderr.
load test_helper/common

setup() { WORK="$(mktemp -d)"; }
teardown() { rm -rf "$WORK"; }

cfg() { printf 'SLUICE_NAME="sectest-home"\nSLUICE_RUN_CMD="true"\n' > "$1/sluice.config.sh"; }

@test "home-guard: refuses when the project dir IS \$HOME" {
  cfg "$WORK"
  run bash -c "cd '$WORK' && HOME='$WORK' SLUICE_ENGINE=false '$SLUICE' run true"
  assert_failure
  assert_output --partial "refusing"
  assert_output --partial "home directory"
}

@test "home-guard: refuses when the project dir is an ANCESTOR of \$HOME" {
  mkdir -p "$WORK/home/user"
  cfg "$WORK"
  run bash -c "cd '$WORK' && HOME='$WORK/home/user' SLUICE_ENGINE=false '$SLUICE' run true"
  assert_failure
  assert_output --partial "refusing"
  assert_output --partial "ancestor"
}

@test "home-guard: SLUICE_ALLOW_HOME=1 overrides the refusal" {
  cfg "$WORK"
  run bash -c "cd '$WORK' && HOME='$WORK' SLUICE_ALLOW_HOME=1 SLUICE_ENGINE=false '$SLUICE' run true"
  refute_output --partial "refusing"
}

@test "home-guard: a normal project subdir under \$HOME is allowed (no refusal)" {
  mkdir -p "$WORK/home/user/proj"
  cfg "$WORK/home/user/proj"
  run bash -c "cd '$WORK/home/user/proj' && HOME='$WORK/home/user' SLUICE_ENGINE=false '$SLUICE' run true"
  refute_output --partial "refusing"
}
