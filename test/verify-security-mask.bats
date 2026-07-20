#!/usr/bin/env bats
# SLUICE_MASK: a masked file reads empty + write-rejected, a masked dir reads empty, the path still
# EXISTS in the box (name visible, content shadowed), unmasked siblings and the host stay untouched.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/mask/secrets"
  echo "SECRET=hunter2" > "$WORK/mask/.env"
  echo "key-material" > "$WORK/mask/secrets/private.pem"
  echo "readable" > "$WORK/mask/normal.txt"
  mkdir -p "$WORK/mask/config"
  echo "LINKSECRET=hunter3" > "$WORK/mask/config/real.env"
  ( cd "$WORK/mask" && ln -s config/real.env .env.link )   # a .env*-matching symlink to an in-project secret
  cat > "$WORK/mask/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-mask"
SLUICE_MASK=".env* secrets"
SLUICE_RUN_CMD="bash"
CFG
  ( cd "$WORK/mask" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  destroy_box mask mask
  local extra
  for extra in sluice-sectest-mask-off sluice-sectest-mask-audit sluice-sectest-mask-audit-audit; do
    "$ENG" rm -f -v "$extra" >/dev/null 2>&1 || true   # 2nd boxes some @tests create
    "$ENG" rmi -f "$extra" >/dev/null 2>&1 || true
  done
}

@test "mask: a masked file reads empty in the box" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'wc -c < .env' 2>/dev/null"
  assert_output "0"   # exact: --partial "0" fail-opens on any byte count containing a 0 (10, 15, 100)
}

@test "mask: a masked file is read-only (write rejected)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'echo leak > .env'"
  assert_failure
}

@test "mask: a masked dir reads empty (its files are gone)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'ls -A secrets | wc -l' 2>/dev/null"
  assert_output "0"   # exact: --partial "0" fail-opens on any line count containing a 0
}

@test "mask: the masked path still exists in the box (name visible, content shadowed)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'test -e .env && test -d secrets && echo present' 2>/dev/null"
  assert_output "present"
}

@test "mask: a masked symlink shadows its in-project target (unreadable via the link)" {
  run bash -c "cd '$WORK/mask' && '$SLUICE' run sh -c 'wc -c < .env.link' 2>/dev/null"
  assert_output "0"                                        # reading THROUGH the link hits the emptied target
  run bash -c "cd '$WORK/mask' && '$SLUICE' run cat config/real.env 2>/dev/null"
  refute_output --partial "hunter3"                        # the real target file is shadowed empty
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

@test "mask: launch shows a count; doctor lists the masks" {
  ( cd "$WORK/mask" && "$SLUICE" stop ) >/dev/null 2>&1 || true
  run bash -c "cd '$WORK/mask' && '$SLUICE' run true 2>&1"
  assert_output --partial "masking"
  assert_output --partial "in-repo path(s)"     # a count, not the verbatim match list
  assert_output --partial "see 'sluice doctor'"
  run bash -c "cd '$WORK/mask' && '$SLUICE' doctor 2>&1"
  assert_output --partial ".env"                # doctor still surfaces the masks
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
  assert_output --partial "SECRET=visible"   # --partial: the first run interleaves build/start lines
  ( cd "$WORK/mask-off" 2>/dev/null && "$SLUICE" rm ) >/dev/null 2>&1 || true
}

@test "mask: stays in force during 'learn --audit' (the open-egress pass)" {
  mkdir -p "$WORK/mask-audit"
  echo "SECRET=hunter2" > "$WORK/mask-audit/.env"
  cat > "$WORK/mask-audit/sluice.config.sh" <<CFG
SLUICE_NAME="sectest-mask-audit"
SLUICE_MASK=".env*"
SLUICE_RUN_CMD='printf MASKBYTES=%s\\\\n "\$(wc -c < .env)"'
CFG
  # The audit run reaches no hosts (the cmd is local-only), so it exits 0 after printing.
  run bash -c "cd '$WORK/mask-audit' && SLUICE_YES=1 '$SLUICE' learn --audit 2>&1"
  assert_success
  assert_output --partial "MASKBYTES=0"        # .env is the empty masked bind during the audit pass
  refute_output --partial "hunter2"
  ( cd "$WORK/mask-audit" && "$SLUICE" rm ) >/dev/null 2>&1 || true
}
