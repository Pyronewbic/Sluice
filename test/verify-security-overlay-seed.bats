#!/usr/bin/env bats
# SLUICE_WORKSPACE=overlay seed-failure data-safety (B5): if the entrypoint's `cp -a /mnt/sluice-orig/.`
# seed into the writable copy partially fails (cp -a does partial copies, exits non-zero on per-file
# errors), the working copy is SHORT a file the orig still has. The old entrypoint swallowed the seed
# failure (`|| true`) and wrote /run/sluice-orig-manifest anyway from an independent `find` over the
# (complete) orig - so `sluice apply` computed the un-copied file as a box DELETION and rm'd it from the
# HOST repo. The fix gates the manifest on a fully-successful seed: a failed seed skips the snapshot +
# warns, and apply's existing "no snapshot -> skip deletions" branch spares the host file.
#
# Trigger: a read-only SLUICE_MOUNTS bind over a dest SUBDIR forces cp into that subdir to EROFS, so the
# file inside it is never seeded, while `find /mnt/sluice-orig` still lists it. Docker-gated (CI's
# security leg is authoritative); runs on Docker Desktop too. @tests run in file order: inspect the seed
# state first, then the apply that must NOT delete.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ws/sub" "$WORK/roblock"
  echo blocker > "$WORK/roblock/.keep"           # a separate ro host dir to shadow the dest subdir
  echo top      > "$WORK/ws/top.txt"
  echo precious > "$WORK/ws/sub/inner.txt"        # the host file the failed seed must NOT cost us
  # The dest subdir ($PROJECT_DIR/sub == $WORK/ws/sub) is bound READ-ONLY over the writable copy, so the
  # entrypoint's `cp -a` EROFS-fails writing sub/inner.txt (partial seed). Write the literal path: the
  # entrypoint sources this config in-container where $PROJECT_DIR is undefined.
  { printf 'SLUICE_NAME="sectest-ovseed"\n'
    printf 'SLUICE_WORKSPACE=overlay\n'
    printf 'SLUICE_RUN_CMD="bash"\n'
    printf 'SLUICE_MOUNTS="%s:%s:ro"\n' "$WORK/roblock" "$WORK/ws/sub"
  } > "$WORK/ws/sluice.config.sh"
  ( cd "$WORK/ws" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() { destroy_box ovseed ws; }   # roblock lives under $WORK, nuked with the tree

@test "overlay-seed: the seed really was partial (working copy is missing the host file)" {
  # the orig (what find walks) has sub/inner.txt; the writable copy must NOT (cp EROFS'd it)
  run "$ENG" exec sluice-sectest-ovseed sh -c 'test -f /mnt/sluice-orig/sub/inner.txt && echo orig-has'
  assert_output "orig-has"
  run "$ENG" exec sluice-sectest-ovseed sh -c 'test -f "$SLUICE_WORKDIR/sub/inner.txt" && echo copy-has || echo copy-missing'
  assert_output "copy-missing"
}

@test "overlay-seed: a failed seed SKIPS the apply-safety manifest (no false deletion baseline)" {
  run "$ENG" exec sluice-sectest-ovseed sh -c 'test -f /run/sluice-orig-manifest && echo present || echo absent'
  assert_output "absent"
}

@test "overlay-seed: the incomplete-seed warning was emitted on boot" {
  run "$ENG" logs sluice-sectest-ovseed
  assert_output --partial "overlay seed copy was incomplete"
}

@test "overlay-seed: sluice apply does NOT delete the host file the seed never copied (B5)" {
  [ -f "$WORK/ws/sub/inner.txt" ]                       # host file present before apply
  ( cd "$WORK/ws" && SLUICE_YES=1 "$SLUICE" apply ) >/dev/null 2>&1 || true
  [ -f "$WORK/ws/sub/inner.txt" ]                       # MUST still be there (not rm'd from the host)
  [ "$(cat "$WORK/ws/sub/inner.txt")" = precious ]      # and unchanged
}
