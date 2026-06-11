#!/usr/bin/env bats
# SLUICE_MOUNTS: a :ro bind is readable but not writable inside the box. Ported from verify-security.sh.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/mnt"
  echo ro-content > "$WORK/mnt/ro-source.txt"
  cat > "$WORK/mnt/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-mnt"
SLUICE_MOUNTS="$WORK/mnt/ro-source.txt:/home/sluice/ro-mounted.txt:ro"
SLUICE_RUN_CMD="bash"
CFG
  ( cd "$WORK/mnt" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() { destroy_box mnt mnt; }

@test "mounts: a :ro bind is readable in the box" {
  run bash -c "cd '$WORK/mnt' && '$SLUICE' run cat /home/sluice/ro-mounted.txt 2>/dev/null"
  assert_output "ro-content"
}

@test "mounts: a :ro bind is read-only (write rejected)" {
  run bash -c "cd '$WORK/mnt' && '$SLUICE' run sh -c 'echo x > /home/sluice/ro-mounted.txt'"
  assert_failure
}
