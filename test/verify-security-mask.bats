#!/usr/bin/env bats
# SLUICE_MASK: a masked file reads empty + write-rejected, a masked dir reads empty, the path still
# EXISTS in the box (name visible, content shadowed), unmasked siblings and the host stay untouched.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/mask/secrets"
  echo "SECRET=hunter2" > "$WORK/mask/.env"
  echo "key-material" > "$WORK/mask/secrets/private.pem"
  echo "readable" > "$WORK/mask/normal.txt"
  cat > "$WORK/mask/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-mask"
SLUICE_MASK=".env* secrets"
SLUICE_RUN_CMD="bash"
CFG
  ( cd "$WORK/mask" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  chown_back_tree sluice-sectest-mask "$WORK"
  ( cd "$WORK/mask" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-mask sluice-sectest-mask-off >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-mask sluice-sectest-mask-off >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "mask: a masked file reads empty in the box" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'wc -c < .env' 2>/dev/null"
  assert_output --partial "0"
}

@test "mask: a masked file is read-only (write rejected)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'echo leak > .env'"
  assert_failure
}

@test "mask: a masked dir reads empty (its files are gone)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'ls -A secrets | wc -l' 2>/dev/null"
  assert_output --partial "0"
}

@test "mask: the masked path still exists in the box (name visible, content shadowed)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'test -e .env && test -d secrets && echo present' 2>/dev/null"
  assert_output "present"
}

@test "mask: an unmasked sibling is untouched" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run cat normal.txt 2>/dev/null"
  assert_output "readable"
}

@test "mask: the host files keep their contents" {
  run grep -q "hunter2" "$WORK/mask/.env"
  assert_success
  run grep -q "key-material" "$WORK/mask/secrets/private.pem"
  assert_success
}

@test "mask: launch output lists the active masks" {
  ( cd "$WORK/mask" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/mask' && '$SLUICE' run true 2>&1"
  assert_output --partial "masking"
  assert_output --partial ".env"
  assert_output --partial "secrets"
}

@test "mask: an absolute pattern is rejected (die)" {
  mkdir -p "$WORK/mask-bad"
  printf 'SLUICE_NAME="sectest-mask"\nSLUICE_MASK="/etc"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/mask-bad/sluice.config.sh"
  ( cd "$WORK/mask-bad" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/mask-bad' && '$SLUICE' run true"
  assert_failure
  assert_output --partial "SLUICE_MASK"
}

@test "mask: explicitly empty SLUICE_MASK disables masking" {
  mkdir -p "$WORK/mask-off"
  echo "SECRET=visible" > "$WORK/mask-off/.env"
  printf 'SLUICE_NAME="sectest-mask-off"\nSLUICE_MASK=""\nSLUICE_RUN_CMD="bash"\n' > "$WORK/mask-off/sluice.config.sh"
  run bash -c "cd '$WORK/mask-off' && '$SLUICE' run cat .env 2>/dev/null"
  assert_output "SECRET=visible"
  ( cd "$WORK/mask-off" 2>/dev/null && "$SLUICE" rm ) >/dev/null 2>&1 || true
}
