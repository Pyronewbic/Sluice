#!/usr/bin/env bats
# Per-host egress byte budgets (unit; no engine). SLUICE_EGRESS_HOST_BUDGETS caps tx bytes PER reached
# host (a tighter laundering bound than the whole-box SLUICE_EGRESS_MAX_BYTES): over any host's cap,
# `sluice egress` exits non-zero (the CI gate). This suite stubs the squid-log reader (the
# verify-receipt-unit pattern) so the resolver (_host_budget_for), the gate (cmd_egress), and the
# JSON fields (budget / over_budget) run with no box: exact-vs-wildcard precedence, longest-wildcard-
# wins, the tx==cap boundary, malformed-token fail-closed validation, and non-zero exit on breach.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  SLUICE_BIN="${src%/src}/bin/sluice"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"; source "$src/20-lock-sbom-scan.sh"
  container="sluice-hbtest"; slug="hbtest"; SLUICE_ALLOW_DOMAINS=""
  running() { return 0; }        # pretend the box is up (cmd_egress guards on it)
  _audit_readable() { return 0; }
}

# --- _host_budget_for: token resolution (pure shell) ----------------------------------------------
@test "host-budget: an exact host token resolves to its byte cap" {
  SLUICE_EGRESS_HOST_BUDGETS="api.example.com=2048"
  run _host_budget_for api.example.com
  assert_output "2048"
}

@test "host-budget: a leading-dot wildcard matches the bare host and subdomains" {
  SLUICE_EGRESS_HOST_BUDGETS=".s3.amazonaws.com=1048576"
  run _host_budget_for a.s3.amazonaws.com
  assert_output "1048576"
  run _host_budget_for s3.amazonaws.com
  assert_output "1048576"
}

@test "host-budget: an exact match beats a covering wildcard" {
  SLUICE_EGRESS_HOST_BUDGETS=".example.com=100 api.example.com=999"
  run _host_budget_for api.example.com
  assert_output "999"
}

@test "host-budget: among wildcards the longest (most specific) wins" {
  SLUICE_EGRESS_HOST_BUDGETS=".example.com=100 .api.example.com=500"
  run _host_budget_for x.api.example.com
  assert_output "500"
}

@test "host-budget: a host with no matching token resolves to empty (no budget)" {
  SLUICE_EGRESS_HOST_BUDGETS=".example.com=100"
  run _host_budget_for other.test
  assert_output ""
}

@test "host-budget: a glob metachar in a token is not expanded against CWD (set -f)" {
  # a bogus token containing '*' must not glob into filenames and must simply not match a real host
  SLUICE_EGRESS_HOST_BUDGETS="*=100 api.example.com=2048"
  run _host_budget_for api.example.com
  assert_output "2048"
}

# --- validation (src/60): fail closed on a malformed token ----------------------------------------
_run_validate() {  # $1 = SLUICE_EGRESS_HOST_BUDGETS value
  local t="$BATS_TEST_TMPDIR/vhb.sh"
  {
    echo 'set -euo pipefail'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    sed -n '/^validate_host_budgets()/,/^}/p' "$SLUICE_BIN"
    echo 'validate_host_budgets'
  } > "$t"
  SLUICE_EGRESS_HOST_BUDGETS="$1" run bash "$t"
}

@test "host-budget: a token with no '=' dies (fail closed)" {
  _run_validate "api.example.com"
  assert_failure
  assert_output --partial "must be host=bytes"
}

@test "host-budget: a non-numeric byte count dies" {
  _run_validate "api.example.com=lots"
  assert_failure
  assert_output --partial "is not a byte count"
}

@test "host-budget: an invalid host charset dies" {
  _run_validate 'ho st.example.com=100'
  assert_failure
}

@test "host-budget: a well-formed multi-token value validates" {
  _run_validate ".s3.amazonaws.com=1048576 api.example.com=2048"
  assert_success
}

# --- cmd_egress gate: over-budget host makes egress exit non-zero ---------------------------------
# Stub _squid_log with a fixture where evil.example.com uploaded 200 bytes (tx=200). Its 100-byte
# budget is exceeded, so cmd_egress must exit non-zero (the CI gate) and JSON must flag over_budget.
_fixture_log() {
  # one squid access line: TCP_TUNNEL/200, host via ssl_sni, tx=200 rx=10
  printf '1700000000.000 1 10.0.0.2 TCP_TUNNEL/200 210 CONNECT evil.example.com:443 - HIER_DIRECT/1.2.3.4 - ssl_sni=evil.example.com tx=200 rx=10\n'
}

@test "host-budget gate: a host over its cap makes 'sluice egress' exit non-zero" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_HOST_BUDGETS="evil.example.com=100"
  run cmd_egress
  assert_failure
  assert_output --partial "host budget EXCEEDED"
}

@test "host-budget gate: at or under the cap, egress stays green (tx==cap passes)" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_HOST_BUDGETS="evil.example.com=200"   # tx==cap: not over
  run cmd_egress
  assert_success
  refute_output --partial "host budget EXCEEDED"
}

@test "host-budget --json: over-budget host carries budget + over_budget:true" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_HOST_BUDGETS="evil.example.com=100"
  run cmd_egress --json
  assert_failure
  jq -e '.hosts[]|select(.host=="evil.example.com")|.budget==100 and .over_budget==true' <<<"$output"
}

@test "host-budget --json: a host with no budget carries budget:null, over_budget:false" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_HOST_BUDGETS=".other.test=100"   # does not match evil.example.com
  run cmd_egress --json
  assert_success
  jq -e '.hosts[]|select(.host=="evil.example.com")|.budget==null and .over_budget==false' <<<"$output"
}
