#!/usr/bin/env bats
# `sluice apply` (SLUICE_WORKSPACE=overlay) safety: it must NOT apply non-interactively without
# SLUICE_YES (B3), must NOT delete a host file created mid-session (B4 - the live /mnt/sluice-orig
# data-loss), and SLUICE_APPLY_NO_DELETE=1 must keep box-deleted host files. One box; @tests run in
# file order (the non-destructive refuse first, then NO_DELETE, then the deleting apply).
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ws"
  printf 'SLUICE_NAME="sectest-apply"\nSLUICE_WORKSPACE=overlay\nSLUICE_RUN_CMD="bash"\n' > "$WORK/ws/sluice.config.sh"
  echo keep > "$WORK/ws/keep.txt"
  echo gone > "$WORK/ws/gone.txt"
  # box: modify keep, add a file, delete gone (all in the writable copy; host stays protected)
  ( cd "$WORK/ws" && "$SLUICE" run sh -c 'echo MODIFIED > keep.txt; echo NEW > added.txt; rm -f gone.txt' ) >/dev/null 2>&1 || true
  # host creates a file AFTER the box booted - this is what B4 used to delete
  echo host-side > "$WORK/ws/host-new.txt"
}

teardown_file() { destroy_box apply ws; }

@test "apply: refuses non-interactively without SLUICE_YES (B3)" {
  run bash -c "cd '$WORK/ws' && '$SLUICE' apply"
  assert_output --partial "non-interactive"
  # nothing written: host repo untouched
  [ "$(cat "$WORK/ws/keep.txt")" = keep ]
  [ ! -f "$WORK/ws/added.txt" ]
  [ -f "$WORK/ws/gone.txt" ]
}

@test "apply: SLUICE_APPLY_NO_DELETE=1 writes adds/mods but keeps box-deleted host files" {
  run bash -c "cd '$WORK/ws' && SLUICE_YES=1 SLUICE_APPLY_NO_DELETE=1 '$SLUICE' apply 2>&1"
  assert_output --partial "NO_DELETE"
  [ "$(cat "$WORK/ws/keep.txt")" = MODIFIED ]   # modification applied
  [ -f "$WORK/ws/added.txt" ]                    # add applied
  [ -f "$WORK/ws/gone.txt" ]                     # deletion withheld
  [ -f "$WORK/ws/host-new.txt" ]                 # host file untouched
}

@test "apply: deletes box-deleted files but spares a host file created mid-session (B4)" {
  ( cd "$WORK/ws" && SLUICE_YES=1 "$SLUICE" apply ) >/dev/null 2>&1
  [ ! -f "$WORK/ws/gone.txt" ]                   # box deletion now propagated
  [ -f "$WORK/ws/host-new.txt" ]                 # host-created file NOT mistaken for a deletion
  [ "$(cat "$WORK/ws/host-new.txt")" = host-side ]
  [ "$(cat "$WORK/ws/keep.txt")" = MODIFIED ]
}
