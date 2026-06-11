#!/usr/bin/env bats
# git worktree support: sluice mounts the git common dir so git resolves inside the box, and exports
# SLUICE_GITDIR. Ported from verify-security.sh.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  ( cd "$WORK" && git init -q repo && cd repo && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init ) >/dev/null 2>&1 || true
  export WT; WT="$WORK/wt"
  ( cd "$WORK/repo" && git worktree add -q "$WT" ) >/dev/null 2>&1 || true
  printf 'SLUICE_NAME="sectest-wt"\nSLUICE_RUN_CMD="bash"\n' > "$WT/sluice.config.sh"
  ( cd "$WT" && "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() { destroy_box wt wt; }   # WT == WORK/wt; nuke_tree clears the repo + worktree

@test "worktree: git resolves inside the box (common dir mounted)" {
  run bash -c "cd '$WT' && '$SLUICE' run git -C '$WT' status"
  assert_success
}

@test "worktree: SLUICE_GITDIR is set in the box" {
  run bash -c "cd '$WT' && '$SLUICE' run printenv SLUICE_GITDIR"
  assert_success
  refute_output ""
}
