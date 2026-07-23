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

# --- high_volume: the flag the receipt has always carried, now on `sluice egress` too ---------------
# docs/configuration.md documented `sluice egress --json` as emitting this field before it did, so a CI
# gate written against the documented contract silently never fired. The fixture row is tx=200 rx=10;
# the flag compares field 4 (tx+rx = 210), NOT tx - a large download trips it just as an upload does.

@test "high-volume --json: a reached host at or over the threshold carries high_volume:true" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_FLAG_BYTES=210   # == tx+rx: the boundary is inclusive, matching the receipt
  run cmd_egress --json
  assert_success
  jq -e '.hosts[]|select(.host=="evil.example.com")|.high_volume==true' <<<"$output"
}

# Pins the measure: a threshold ABOVE tx but BELOW tx+rx still flags, so a large inbound transfer
# trips it. Documenting this as "tx bytes" understated what the flag actually catches.
@test "high-volume --json: a threshold between tx and tx+rx still flags (the flag counts both)" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_FLAG_BYTES=205   # above tx (200), below tx+rx (210)
  run cmd_egress --json
  assert_success
  jq -e '.hosts[]|select(.host=="evil.example.com")|.high_volume==true' <<<"$output"
}

@test "high-volume --json: a host under the threshold carries high_volume:false" {
  _squid_log() { _fixture_log; }
  run cmd_egress --json            # default threshold is 1 GiB; the fixture moved 210 B
  assert_success
  jq -e '.hosts[]|select(.host=="evil.example.com")|.high_volume==false' <<<"$output"
}

@test "high-volume --json: =0 disables the flag rather than flagging every reached host" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_FLAG_BYTES=0
  run cmd_egress --json
  assert_success
  jq -e '.hosts[]|select(.host=="evil.example.com")|.high_volume==false' <<<"$output"
}

@test "high-volume: the human render tags the row, matching the receipt's wording" {
  _squid_log() { _fixture_log; }
  SLUICE_EGRESS_FLAG_BYTES=100
  run cmd_egress
  assert_success
  assert_output --partial "(high volume)"
}

# The refute needs an anchor: cmd_egress early-returns "(nothing yet - exercise the app...)" on an
# empty log and still exits 0, so a bare refute_output passes having rendered no row at all - green
# on main, and green against a regression that dropped reached rows entirely. Assert the row IS there.
@test "high-volume: an under-threshold human render carries no tag" {
  _squid_log() { _fixture_log; }
  run cmd_egress
  assert_success
  assert_output --partial "evil.example.com"
  assert_output --partial "210 B"
  refute_output --partial "(high volume)"
}

# The GB/TB ladder landed in the receipt renderer only, so `sluice egress` still printed a
# multi-gigabyte transfer as "5222.4 MB". LC_ALL=C is already pinned on this awk (bwk/mawk take the
# %f radix from the locale); this asserts the ladder itself.
@test "high-volume: the human render carries the GB ladder, not a four-digit MB" {
  _squid_log() { printf '1700000000.000 1 10.0.0.2 TCP_TUNNEL/200 210 CONNECT bulk.example.com:443 - HIER_DIRECT/1.2.3.4 - ssl_sni=bulk.example.com tx=5476083302 rx=0\n'; }
  run cmd_egress
  assert_success
  assert_output --partial "5.10 GB"
  refute_output --partial "5222.4 MB"
}

# The row's byte total also feeds the high-volume flag. On mawk %d truncated a 5.10 GB transfer to
# ~2.0 GB, sliding it UNDER a 3 GiB threshold so the exfil never flagged - a security dodge, not just
# a cosmetic render. (Only fails on truncating mawk; the VM lane is the one that catches it.)
@test "high-volume: a >2GiB transfer over a >2GiB threshold IS flagged (no int32 truncation dodge)" {
  _squid_log() { printf '1700000000.000 1 10.0.0.2 TCP_TUNNEL/200 210 CONNECT bulk.example.com:443 - HIER_DIRECT/1.2.3.4 - ssl_sni=bulk.example.com tx=5476083302 rx=0\n'; }
  SLUICE_EGRESS_FLAG_BYTES=3221225472    # 3 GiB: above the truncated 2.0 GB, below the real 5.10 GB
  run cmd_egress
  assert_success
  assert_output --partial "(high volume)"
}
