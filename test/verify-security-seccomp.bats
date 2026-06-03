#!/usr/bin/env bats
# SLUICE_SECCOMP=hardened (opt-in): the userns/namespace syscall class is EPERM'd while normal
# fork/exec is untouched; without the knob no sluice seccomp profile is applied. Ported from
# verify-security.sh. The unshare-binary-present check is its own @test so a missing binary can't
# false-pass the block test (the bug the old harness had).
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/sc"
  # util-linux-misc ships /usr/bin/unshare (the real syscall vector under test).
  printf 'SLUICE_NAME="sectest-seccomp"\nSLUICE_EXTRA_PKGS="util-linux-misc"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sc/sluice.config.sh"
  ( cd "$WORK/sc" && SLUICE_SECCOMP=hardened "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  chown_back_tree sluice-sectest-seccomp "$WORK"
  ( cd "$WORK/sc" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-seccomp >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-seccomp >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "seccomp: the unshare binary is present (so the block test is real)" {
  run "$ENG" exec sluice-sectest-seccomp sh -c 'command -v unshare'
  assert_success
}

@test "seccomp: the hardened profile is applied" {
  run "$ENG" inspect sluice-sectest-seccomp --format '{{.HostConfig.SecurityOpt}}'
  assert_output --partial "seccomp"
}

@test "seccomp: unshare(CLONE_NEWUSER) is blocked (EPERM)" {
  run "$ENG" exec --user sluice sluice-sectest-seccomp unshare -Ur true
  assert_failure
}

@test "seccomp: normal fork/exec still works" {
  run "$ENG" exec --user sluice sluice-sectest-seccomp sh -c 'echo hi | cat >/dev/null && echo ok'
  assert_output "ok"
}

@test "seccomp: a default run (no SLUICE_SECCOMP) applies no sluice profile" {
  ( cd "$WORK/sc" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  ( cd "$WORK/sc" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  run "$ENG" inspect sluice-sectest-seccomp --format '{{.HostConfig.SecurityOpt}}'
  refute_output --partial "seccomp="
}
