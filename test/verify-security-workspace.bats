#!/usr/bin/env bats
# SLUICE_WORKSPACE=overlay: the host repo is protected (the box edits a writable copy), `sluice diff`
# shows the change, and `sluice apply` writes it back. Ported from verify-security.sh.
# The @tests run in file order: the host-protected / diff checks precede apply (which mutates the host).
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ws"
  printf 'SLUICE_NAME="sectest-ws"\nSLUICE_WORKSPACE=overlay\nSLUICE_RUN_CMD="bash"\n' > "$WORK/ws/sluice.config.sh"
  echo original > "$WORK/ws/file.txt"
  ( cd "$WORK/ws" && "$SLUICE" run sh -c 'echo MODIFIED > file.txt; echo NEWFILE > added.txt' ) >/dev/null 2>&1 || true
}

teardown_file() { destroy_box ws ws; }

@test "workspace: the host repo is protected (box edit didn't reach it)" {
  run cat "$WORK/ws/file.txt"
  assert_output "original"
}

@test "workspace: the box's new file stayed in the copy" {
  [ ! -f "$WORK/ws/added.txt" ]
}

@test "workspace: diff shows the box's change" {
  run bash -c "cd '$WORK/ws' && '$SLUICE' diff 2>/dev/null"
  assert_output --partial "+MODIFIED"
}

@test "workspace: apply writes the changes back to the host" {
  ( cd "$WORK/ws" && SLUICE_YES=1 "$SLUICE" apply ) >/dev/null 2>&1 || true
  [ "$(cat "$WORK/ws/file.txt")" = MODIFIED ]
  [ -f "$WORK/ws/added.txt" ]
}
