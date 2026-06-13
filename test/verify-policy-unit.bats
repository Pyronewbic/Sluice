#!/usr/bin/env bats
# Central-policy pure helpers (unit; no engine). CIDR membership for deny-ip and the deny-host
# wildcard matcher are extracted from the built launcher and exercised in isolation - they decide
# what an org policy refuses, so they get direct coverage.
load test_helper/common

setup() {
  # Pull just the pure function defs out of bin/sluice (don't source it - that runs the whole CLI).
  eval "$(sed -n '/^_ip2int()/,/^}/p; /^_ip_in_cidr()/,/^}/p; /^_policy_denied_host()/,/^}/p; /^_allow_covers_denied()/,/^}/p' "$ROOT/bin/sluice")"
}

@test "cidr: an IP inside a /8 matches" { run _ip_in_cidr 10.0.0.5 10.0.0.0/8; assert_success; }
@test "cidr: an IP outside a /8 does not match" { run _ip_in_cidr 11.0.0.5 10.0.0.0/8; assert_failure; }
@test "cidr: a /24 boundary is respected" {
  run _ip_in_cidr 192.168.1.9 192.168.1.0/24; assert_success
  run _ip_in_cidr 192.168.2.9 192.168.1.0/24; assert_failure
}
@test "cidr: a bare IP matches only itself" {
  run _ip_in_cidr 1.2.3.4 1.2.3.4; assert_success
  run _ip_in_cidr 1.2.3.5 1.2.3.4; assert_failure
}

@test "deny-host: an exact host is denied" { run _policy_denied_host pastebin.com "pastebin.com gist.github.com"; assert_success; }
@test "deny-host: a leading-dot wildcard denies subdomains" { run _policy_denied_host x.pastebin.com ".pastebin.com"; assert_success; }
@test "deny-host: an unrelated host is not denied" { run _policy_denied_host safe.example.com "pastebin.com"; assert_failure; }

# An allow .parent wildcard that covers a denied host must be caught (else local config defeats the deny).
@test "allow-covers-deny: a .parent allow wildcard covering a denied host is flagged" { run _allow_covers_denied .githubusercontent.com "gist.githubusercontent.com"; assert_success; }
@test "allow-covers-deny: an exact allow host is never flagged (only wildcards over-admit)" { run _allow_covers_denied raw.githubusercontent.com "gist.githubusercontent.com"; assert_failure; }
@test "allow-covers-deny: a wildcard not covering the deny is not flagged" { run _allow_covers_denied .example.com "gist.githubusercontent.com"; assert_failure; }
@test "allow-covers-deny: a broad wildcard covering a deny-wildcard token is flagged" { run _allow_covers_denied .com ".evil.com"; assert_success; }

# learn_apply's policy fetch must fail CLOSED: an unreachable SLUICE_POLICY_URL must abort the apply
# (nothing added/written/reloaded) rather than proceed without the deny list, matching apply_policy.
# Build a self-contained script (stubs + the extracted function) and run it under the launcher's
# set -euo pipefail, the way the real launcher executes.
@test "policy: learn fails closed when SLUICE_POLICY_URL is configured but unreachable" {
  local t="$BATS_TEST_TMPDIR/learn_failclosed.sh"
  cat > "$t" <<'STUBS'
set -euo pipefail
policy_configured() { return 0; }                           # a policy IS configured
_policy_raw() { echo "policy unreachable" >&2; exit 1; }    # mimics the real die on a dead URL
apply_allowlist() { echo "MUTATED:apply"; }                 # tripwires: must NOT run
reload_allowlist() { echo "MUTATED:reload"; }
merge_allow() { printf '%s' "$1"; }
doh_listed() { return 1; }
laundering_host() { return 1; }
_policy_denied_host() { return 1; }
_allow_covers_denied() { return 1; }
_tilde() { printf '%s' "$1"; }
PROJECT_CONFIG=/dev/null; E_YEL=''; E_RST=''; C_GRN=''; C_RST=''; C_DIM=''
STUBS
  sed -n '/^learn_apply()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  echo 'learn_apply "pastebin.com"' >> "$t"
  run bash "$t"
  assert_failure
  refute_output --partial "MUTATED"
}

@test "policy: learn applies normally when no policy is configured (deny fetch skipped)" {
  local t="$BATS_TEST_TMPDIR/learn_nopolicy.sh"
  cat > "$t" <<'STUBS'
set -euo pipefail
policy_configured() { return 1; }                           # no policy -> no fetch
_policy_raw() { echo "SHOULD-NOT-FETCH"; exit 1; }          # tripwire: must NOT be called
apply_allowlist() { echo "APPLIED:$1"; }
reload_allowlist() { return 0; }
merge_allow() { printf '%s' "$1"; }
doh_listed() { return 1; }
laundering_host() { return 1; }
_policy_denied_host() { return 1; }
_allow_covers_denied() { return 1; }
_tilde() { printf '%s' "$1"; }
PROJECT_CONFIG=/dev/null; E_YEL=''; E_RST=''; C_GRN=''; C_RST=''; C_DIM=''
STUBS
  sed -n '/^learn_apply()/,/^}/p' "$ROOT/bin/sluice" >> "$t"
  echo 'learn_apply "example.org"' >> "$t"
  run bash "$t"
  assert_success
  assert_output --partial "APPLIED:example.org"
  refute_output --partial "SHOULD-NOT-FETCH"
}
