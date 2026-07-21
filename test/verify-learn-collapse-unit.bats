#!/usr/bin/env bats
# _learn_review's wildcard-collapse offer (unit; no engine). The offer loop builds `subs` from a command
# substitution whose last pipeline stage is a `while` loop. When the final iteration's test fails, the
# `&&` short-circuits, the loop exits 1, pipefail carries it out of the substitution, and the plain
# assignment propagates it - so `set -e` kills `sluice learn` mid-screen with NO error text: the user
# sees the header and a blank line, exit 1. Fires whenever a collapse is offered and the last blocked
# host is not a child of that parent.
#
# Harness notes, all three load-bearing:
#  1. The function is sed-extracted from the BUILT bin/sluice (the verify-hostbudget-unit pattern), so
#     the loop under test is the real shipped text, not a copy retyped here.
#  2. Two mechanical rewrites, neither touching the loop: the interactive `read` is pointed at stdin
#     instead of /dev/tty, and the "both streams non-tty" early return is forced off. Without the
#     second, bats' piped stdout takes that return and the loop never executes - a vacuous pass.
#  3. The function is called BARE, exactly as src/80-learn.sh:342 calls it. Calling it as
#     `_learn_review ... || echo rc=$?` disarms errexit for the whole function body, and every
#     assertion here would pass against the unfixed code.
load test_helper/common

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  SLUICE_BIN="${SRC%/src}/bin/sluice"
  EXTRACT="$BATS_TEST_TMPDIR/learn_review.sh"
  sed -n '/^_learn_review()/,/^}/p' "$SLUICE_BIN" \
    | sed -e 's#</dev/tty#</dev/stdin#' \
          -e 's#if \[ ! -t 0 \] && \[ ! -t 1 \]; then#if false; then#' > "$EXTRACT"
  # Guard the extraction itself: a sed that silently matched nothing would make every test below
  # pass for the wrong reason.
  grep -q 'subs="\$(' "$EXTRACT"
  [ "$(grep -c '/dev/tty' "$EXTRACT")" = 0 ]
}

# $1 = rows ("<host>\t<count>\t<bytes>"), $2 = answers fed to the prompts.
_review() {
  local t="$BATS_TEST_TMPDIR/drive.sh"
  {
    echo 'set -euo pipefail'
    echo ". '$SRC/00-prelude.sh'"
    echo ". '$SRC/10-egress-helpers.sh'"
    echo ". '$EXTRACT'"
    echo 'learn_apply() { echo "APPLY-REACHED"; return 0; }'
    echo 'reload_allowlist() { return 0; }'
    printf '_learn_review "%s" "blocked"\n' "$1"     # bare - see harness note 3
    echo 'echo "SURVIVED"'
  } > "$t"
  printf '%s\n' "$2" | bash "$t" 2>&1
}

# bytes-desc, the order cmd_learn feeds in; the trailing row is NOT a child of example.com.
_rows_trailing_stranger() {
  local TAB; TAB="$(printf '\t')"
  printf 'a.example.com%s1%s300\nb.example.com%s1%s200\nz.other.test%s1%s100' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB"
}

# POSITIVE CONTROL. Proves the harness reaches the collapse offer at all. Without this, the regression
# below could pass because the function early-returned rather than because the bug is fixed.
@test "learn-collapse: the harness reaches the collapse offer (positive control)" {
  run _review "$(_rows_trailing_stranger)" "$(printf 'n\ns\ns\ns')"
  assert_output --partial "collapse to .example.com"
}

# THE REGRESSION. Unfixed, this prints the header and dies: exit 1, no prompt, no error text.
@test "learn-collapse: a trailing non-child host does not abort the review" {
  run _review "$(_rows_trailing_stranger)" "$(printf 'n\ns\ns\ns')"
  assert_success
  assert_output --partial "collapse to .example.com"
  assert_output --partial "SURVIVED"
}

# The mirror case, which always worked - pinned so a fix cannot regress it the other way.
@test "learn-collapse: a trailing child host still offers the collapse" {
  local TAB; TAB="$(printf '\t')"
  run _review "$(printf 'z.other.test%s1%s300\na.example.com%s1%s200\nb.example.com%s1%s100' "$TAB" "$TAB" "$TAB" "$TAB" "$TAB" "$TAB")" "$(printf 's\nn\ns\ns')"
  assert_success
  assert_output --partial "collapse to .example.com"
  assert_output --partial "SURVIVED"
}

# subs feeds both the offer's count and the `handled` set - a truncated list would under-report which
# hosts a collapse covers, and silently leave one blocked after the user accepted.
@test "learn-collapse: the offer counts both subdomains, not one" {
  run _review "$(_rows_trailing_stranger)" "$(printf 'n\ns\ns\ns')"
  assert_success
  assert_output --partial "2 subdomains of example.com"
}

@test "learn-collapse: accepting the collapse consumes both subdomains" {
  run _review "$(_rows_trailing_stranger)" "$(printf 'y\ns')"
  assert_success
  assert_output --partial "collapse to .example.com"
  assert_output --partial "SURVIVED"
}
