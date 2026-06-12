#!/usr/bin/env bats
# Worktree common-dir mount safety (unit; no engine). In non-overlay mode the box owns
# $PROJECT_DIR/.git and could rewrite it to redirect sluice into rw-mounting + chown'ing an arbitrary
# host repo. _validated_git_common_dir mounts the common dir ONLY when the worktree linkage
# back-references THIS repo's .git (a file the box can't forge - it lives outside the box's mount). A
# legit linked worktree still resolves; a non-worktree repo mounts nothing; a redirected .git is refused.
# Each call captures STDOUT only (the mount decision); the refusal warning goes to stderr.
load test_helper/common

setup() {
  # Pull just the helper out of bin/sluice (don't source it - that runs the whole CLI).
  eval "$(sed -n '/^_validated_git_common_dir()/,/^}/p' "$ROOT/bin/sluice")"
  TMP="$(mktemp -d)"
  git init -q "$TMP/main"
  git -C "$TMP/main" -c user.email=a@b.c -c user.name=a commit -q --allow-empty -m init
}
teardown() { rm -rf "$TMP"; }

@test "worktree-mount: a legit linked worktree resolves its (outside) common dir" {
  git -C "$TMP/main" worktree add -q "$TMP/wt" >/dev/null 2>&1
  PROJECT_DIR="$TMP/wt"
  out="$(_validated_git_common_dir 2>/dev/null)"
  assert_equal "$out" "$(cd "$TMP/main/.git" && pwd -P)"
}

@test "worktree-mount: a non-worktree repo mounts nothing extra (common dir is inside the project)" {
  PROJECT_DIR="$TMP/main"
  out="$(_validated_git_common_dir 2>/dev/null)"
  assert_equal "$out" ""
}

@test "worktree-mount: a box-redirected .git is refused - no mount path emitted" {
  git -C "$TMP/main" worktree add -q "$TMP/wt" >/dev/null 2>&1
  git init -q "$TMP/evil"
  # Simulate the box rewriting its own .git pointer at an unrelated repo.
  printf 'gitdir: %s/evil/.git\n' "$TMP" > "$TMP/wt/.git"
  PROJECT_DIR="$TMP/wt"
  out="$(_validated_git_common_dir 2>/dev/null)"
  assert_equal "$out" ""
}
