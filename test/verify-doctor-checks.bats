#!/usr/bin/env bats
# `sluice doctor` project scans that need no box (work with or without an engine daemon):
# SLUICE_MASK posture + the unmasked-secret warning. Each @test gets its own temp project.
load test_helper/common

setup() { WORK="$(mktemp -d)"; }
teardown() { rm -rf "$WORK"; }

@test "doctor: warns on a secret-looking file that is not masked" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "secret-looking"
  assert_output --partial ".env"
  assert_output --partial "SLUICE_MASK"
}

@test "doctor: lists active masks and stops warning once the file is covered" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "mask"
  assert_output --partial "1 path(s) masked"
  refute_output --partial "secret-looking"
}

@test "doctor: a nested secret is NOT covered by a root-level pattern (still warns)" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/packages/api"
  echo "SECRET=1" > "$WORK/packages/api/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "secret-looking"
  assert_output --partial "packages/api/.env"
}

@test "doctor: .env.example is scaffolding, not a secret (no warning)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=" > "$WORK/.env.example"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "secret-looking"
}

@test "doctor: secret scan prunes vendor dirs (node_modules .env ignored)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/node_modules/pkg"
  echo "SECRET=1" > "$WORK/node_modules/pkg/.env"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "secret-looking"
}

@test "doctor --json: mask patterns / masked / unmasked_secrets" {
  printf 'SLUICE_MASK=".env*"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo "SECRET=1" > "$WORK/.env"
  echo "key-material" > "$WORK/server.pem"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m = d['mask']
assert m['patterns'] == ['.env*'], m
assert m['masked'] == ['.env'], m
assert m['unmasked_secrets'] == ['server.pem'], m
"
}

@test "doctor --json: no mask configured -> empty arrays, still valid JSON" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['mask'] == {'patterns': [], 'masked': [], 'unmasked_secrets': []}, d['mask']
"
}

# --- dangling-symlink check ---------------------------------------------------------------------

@test "doctor: warns on a symlink that resolves outside the mounted scope" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  OUTSIDE="$(mktemp -d)"
  echo shared > "$OUTSIDE/shared.md"
  mkdir -p "$WORK/.claude"
  ln -s "$OUTSIDE/shared.md" "$WORK/.claude/CLAUDE.md"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "broken inside the box"
  assert_output --partial ".claude/CLAUDE.md"
  rm -rf "$OUTSIDE"
}

@test "doctor: warns on a dangling out-of-scope symlink (target gone)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  ln -s /nonexistent/elsewhere "$WORK/dangler"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  assert_output --partial "broken inside the box"
  assert_output --partial "dangler"
}

@test "doctor: an in-repo symlink is fine (no warning)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  echo real > "$WORK/real.txt"
  ln -s real.txt "$WORK/alias.txt"
  mkdir -p "$WORK/sub"
  ln -s ../real.txt "$WORK/sub/up.txt"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "broken inside the box"
}

@test "doctor: a worktree symlink into the git common dir is in scope (no warning)" {
  command -v git >/dev/null 2>&1 || skip "git not present"
  ( cd "$WORK" && git init -q main && cd main \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && git worktree add -q "$WORK/wt" >/dev/null 2>&1 )
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/wt/sluice.config.sh"
  ln -s "$WORK/main/.git/HEAD" "$WORK/wt/head-link"
  run bash -c "cd '$WORK/wt' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "head-link"
}

@test "doctor: symlink scan prunes vendor dirs (node_modules .bin links ignored)" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  mkdir -p "$WORK/node_modules/.bin"
  ln -s /usr/bin/true "$WORK/node_modules/.bin/fake"
  run bash -c "cd '$WORK' && '$SLUICE' doctor"
  assert_success
  refute_output --partial "broken inside the box"
}

@test "doctor --json: broken_symlinks lists the project-relative link path" {
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/sluice.config.sh"
  ln -s /nonexistent/elsewhere "$WORK/dangler"
  run bash -c "cd '$WORK' && '$SLUICE' doctor --json 2>/dev/null"
  assert_success
  echo "$output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['broken_symlinks'] == ['dangler'], d['broken_symlinks']
"
}
