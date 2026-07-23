#!/usr/bin/env bats
# The base stage strips every setuid/setgid bit, and the base structure test asserts none remain. But
# SLUICE_EXTRA_PKGS / SLUICE_SETUP_ROOT_CMDS / a pin replay install into the PROJECT stage, AFTER that
# base sweep - so a package carrying setuid-root binaries would ride into the SHIPPED image while every
# base-stage gate stayed green. The project stage mirrors the strip; this proves it with shadow (whose
# chfn/chsh/passwd/gpasswd/chage/expiry are setuid-root on install), the exact escape hatch the docs
# name for re-adding useradd. Needs Docker (engine lane; auto-globbed into SECURITY_BATS).
load test_helper/common

setup_file() {
  make_box setuidstrip ss 'SLUICE_EXTRA_PKGS="shadow"' 'SLUICE_RUN_CMD="true"'
}
teardown_file() { destroy_box setuidstrip ss; }

@test "setuid-strip: box image built with shadow re-added" {
  run "$ENG" image inspect sluice-sectest-setuidstrip
  assert_success
}

# Positive control: without this, a build where shadow silently failed to install would pass the
# no-setuid assertion vacuously (nothing to strip proves nothing about the strip).
@test "setuid-strip: shadow's tools ARE installed in the project image (assertion is not vacuous)" {
  run "$ENG" exec --user root sluice-sectest-setuidstrip sh -c 'command -v useradd'
  assert_success
}

@test "setuid-strip: NO setuid/setgid binary survives the project image (base sweep is mirrored)" {
  # stderr merged into the count so a partial/failed walk fails closed rather than under-counting.
  run "$ENG" exec --user root sluice-sectest-setuidstrip sh -c \
    'find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print 2>&1 | grep -c . | tr -d " "'
  assert_output "0"
}
