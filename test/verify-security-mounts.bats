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

teardown_file() {
  destroy_box mnt mnt
  "$ENG" rm -f -v sluice-sectest-mntset >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-mntset >/dev/null 2>&1 || true
}

@test "mounts: a :ro bind is readable in the box" {
  run bash -c "cd '$WORK/mnt' && '$SLUICE' run cat /home/sluice/ro-mounted.txt 2>/dev/null"
  assert_output "ro-content"
}

@test "mounts: a :ro bind is read-only (write rejected)" {
  run bash -c "cd '$WORK/mnt' && '$SLUICE' run sh -c 'echo x > /home/sluice/ro-mounted.txt'"
  assert_failure
}

# The mount-set guarantee: a plain box (no SLUICE_MOUNTS) exposes ONLY the project dir - nothing else
# of the host, and no Docker socket (which would hand the box control of the daemon).
@test "mounts: a plain box mounts only the project dir and no Docker socket" {
  mkdir -p "$WORK/mntset"
  printf 'SLUICE_NAME="sectest-mntset"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/mntset/sluice.config.sh"
  ( cd "$WORK/mntset" && "$SLUICE" run true ) >/dev/null 2>&1 || true

  run "$ENG" inspect sluice-sectest-mntset --format '{{json .Mounts}}'
  refute_output --partial "docker.sock"

  # Exactly one bind mount, and it is project-dir -> project-dir (nothing else host-visible).
  run "$ENG" inspect sluice-sectest-mntset --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}={{.Destination}}{{println}}{{end}}{{end}}'
  assert_output "$WORK/mntset=$WORK/mntset"
}
