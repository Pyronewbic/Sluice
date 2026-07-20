#!/usr/bin/env bats
# Data handed to awk must survive verbatim on every awk the launcher can meet (macOS one-true-awk,
# Debian/CI mawk, gawk). `awk -v x=VAL` runs ESCAPE PROCESSING on VAL, and the three implementations
# disagree about it: for a domain containing a backslash, bwk silently drops it, mawk keeps it, and
# gawk drops it *and* warns on stderr. Passing through the environment and reading ENVIRON[] instead
# is verbatim everywhere - these tests pin that the allowlist writer never mangles a value.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"
  source "$src/20-lock-sbom-scan.sh"; source "$src/80-learn.sh"
  WORK="$(mktemp -d)"; PROJECT_CONFIG="$WORK/sluice.config.sh"
}
teardown() { rm -rf "$WORK"; }

@test "apply_allowlist: replacing an existing line preserves a backslash verbatim" {
  printf 'SLUICE_NAME="x"\nSLUICE_ALLOW_DOMAINS="old.example.com"\nSLUICE_RUN_CMD="true"\n' > "$PROJECT_CONFIG"
  apply_allowlist 'site\qhost.com other.example.com'
  run grep '^SLUICE_ALLOW_DOMAINS=' "$PROJECT_CONFIG"
  assert_output 'SLUICE_ALLOW_DOMAINS="site\qhost.com other.example.com"'
  # the surrounding config is untouched and the line is not duplicated
  run grep -c '^SLUICE_ALLOW_DOMAINS=' "$PROJECT_CONFIG"
  assert_output "1"
  run grep -c '^SLUICE_RUN_CMD=' "$PROJECT_CONFIG"
  assert_output "1"
}

@test "apply_allowlist: appending when no line exists preserves a backslash verbatim" {
  printf 'SLUICE_NAME="x"\n' > "$PROJECT_CONFIG"
  apply_allowlist 'site\qhost.com'
  run grep '^SLUICE_ALLOW_DOMAINS=' "$PROJECT_CONFIG"
  assert_output 'SLUICE_ALLOW_DOMAINS="site\qhost.com"'
}

@test "apply_allowlist: a plain allowlist round-trips unchanged" {
  printf 'SLUICE_ALLOW_DOMAINS="a.example.com"\n' > "$PROJECT_CONFIG"
  apply_allowlist 'b.example.com c.example.com'
  run grep '^SLUICE_ALLOW_DOMAINS=' "$PROJECT_CONFIG"
  assert_output 'SLUICE_ALLOW_DOMAINS="b.example.com c.example.com"'
}
