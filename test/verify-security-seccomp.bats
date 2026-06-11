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

teardown_file() { destroy_box seccomp sc; }

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

@test "seccomp: personality(ADDR_NO_RANDOMIZE) is blocked under hardened (ASLR can't be self-disabled)" {
  "$ENG" exec sluice-sectest-seccomp sh -c 'command -v setarch' >/dev/null 2>&1 || skip "setarch not in image"
  run "$ENG" exec --user sluice sluice-sectest-seccomp setarch -R true
  assert_failure
}

@test "seccomp: hardened denies userfaultfd + personality (the non-cap-gated default-deny gaps)" {
  grep -v _comment "$ROOT/core/seccomp.json" | grep -q '"userfaultfd"'
  grep -v _comment "$ROOT/core/seccomp.json" | grep -q '"personality"'
}

@test "seccomp: browser profile leaves the userns sandbox calls (unshare/clone/mount) allowed" {
  run bash -c "grep -v _comment '$ROOT/core/seccomp-browser.json' | grep -Eq '\"unshare\"|\"clone\"|\"mount\"|\"pivot_root\"'"
  assert_failure
}

@test "seccomp: browser profile still blocks ptrace + bpf + userfaultfd" {
  grep -v _comment "$ROOT/core/seccomp-browser.json" | grep -q '"ptrace"'
  grep -v _comment "$ROOT/core/seccomp-browser.json" | grep -q '"bpf"'
  grep -v _comment "$ROOT/core/seccomp-browser.json" | grep -q '"userfaultfd"'
}

@test "seccomp: audit transform errors nothing (every ERRNO -> LOG)" {
  run bash -c "sed 's/SCMP_ACT_ERRNO/SCMP_ACT_LOG/g' '$ROOT/core/seccomp.json' | grep -c SCMP_ACT_ERRNO"
  assert_output "0"
}

@test "seccomp: audit transform logs (yields SCMP_ACT_LOG actions)" {
  run bash -c "sed 's/SCMP_ACT_ERRNO/SCMP_ACT_LOG/g' '$ROOT/core/seccomp.json' | grep -c SCMP_ACT_LOG"
  refute_output "0"
}

@test "seccomp: a default run (no SLUICE_SECCOMP) applies no sluice profile" {
  ( cd "$WORK/sc" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  ( cd "$WORK/sc" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  run "$ENG" inspect sluice-sectest-seccomp --format '{{.HostConfig.SecurityOpt}}'
  refute_output --partial "seccomp="
}
