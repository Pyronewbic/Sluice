#!/usr/bin/env bats
# Central-policy CEILING enforcement (unit; no engine). Drives the real policy_evaluate with a stubbed
# _policy_raw: the deny-ip supernet-overlap fix, the fail-CLOSED refusal on a malformed ceiling arg, and
# the max-allow-ips-bytes mandate on the direct-IP lane.
load test_helper/common

setup() {
  # Pull policy_evaluate + the pure helpers it calls out of the built launcher (don't source the CLI).
  eval "$(sed -n '
    /^_ip2int()/,/^}/p
    /^_ip_in_cidr()/,/^}/p
    /^_policy_denied_host()/,/^}/p
    /^_allow_covers_denied()/,/^}/p
    /^laundering_host()/,/^}/p
    /^policy_evaluate()/,/^}/p
  ' "$ROOT/bin/sluice")"
}

# Run the real policy_evaluate against a policy body ($1); echo the refusals it collected.
_refusals() {
  local _pol="$1"
  _policy_raw() { printf '%s\n' "$_pol"; }
  policy_evaluate
  printf '%s' "$_PEVAL_REFUSALS"
}

@test "deny-ip: an entry INSIDE the deny CIDR is refused" {
  SLUICE_ALLOW_IPS="169.254.169.254:80" run _refusals "deny-ip 169.254.169.254/32"
  assert_output --partial "overlaps deny-ip"
}

@test "deny-ip: a SUPERNET entry containing the denied host is refused (the bypass this closes)" {
  SLUICE_ALLOW_IPS="169.254.169.0/24:80" run _refusals "deny-ip 169.254.169.254/32"
  assert_output --partial "overlaps deny-ip"
  SLUICE_ALLOW_IPS="10.0.0.0/8:5432" run _refusals "deny-ip 10.5.0.0/16"
  assert_output --partial "overlaps deny-ip"
}

@test "deny-ip: a disjoint entry is not refused" {
  SLUICE_ALLOW_IPS="192.168.1.5:5432" run _refusals "deny-ip 10.0.0.0/8"
  refute_output --partial "deny-ip"
}

@test "ceiling: a malformed max-hard-cap-bytes arg is a hard refusal, not a silent no-op" {
  run _refusals "max-hard-cap-bytes 10MiB"
  assert_output --partial "max-hard-cap-bytes needs a byte count"
}

@test "ceiling: a malformed max-allow-ips arg refuses" {
  run _refusals "max-allow-ips two"
  assert_output --partial "max-allow-ips needs a number"
}

@test "max-allow-ips-bytes: mandates a direct-IP volume bound when ALLOW_IPS is set" {
  SLUICE_ALLOW_IPS="10.0.0.5:5432" run _refusals "max-allow-ips-bytes 1048576"
  assert_output --partial "SLUICE_ALLOW_IPS_MAX_BYTES <= 1048576"
}

@test "max-allow-ips-bytes: satisfied when the box sets a bound within it" {
  SLUICE_ALLOW_IPS="10.0.0.5:5432" SLUICE_ALLOW_IPS_MAX_BYTES="524288" run _refusals "max-allow-ips-bytes 1048576"
  refute_output --partial "ALLOW_IPS_MAX_BYTES"
}

@test "max-allow-ips-bytes: a no-op when ALLOW_IPS is unset (no direct lane to bound)" {
  run _refusals "max-allow-ips-bytes 1048576"
  refute_output --partial "ALLOW_IPS_MAX_BYTES"
}

# M1: `sluice diff` brings a box up (ensure_up), so it must be gated by apply_policy + the validators.
@test "gate: 'diff' is in the apply_policy + validator gate cases (brings a box up)" {
  [ "$(grep -c 'run-default|run|shell|build|rebuild|update|diff)' "$ROOT/bin/sluice")" -ge 5 ]
  run grep -F 'run-default|run|shell|diff) warn_laundering' "$ROOT/bin/sluice"
  assert_success
}


# --- coverage gaps surfaced by the test-case review (changed-behavior edge/bad paths) ---
@test "ceiling: a malformed max-allow-ips-bytes arg is a hard refusal (not a silent no-op)" {
  SLUICE_ALLOW_IPS="10.0.0.5:5432" run _refusals "max-allow-ips-bytes 10MiB"
  assert_output --partial "max-allow-ips-bytes needs a byte count"
}

@test "max-allow-ips-bytes: a box exceeding the byte cap is refused" {
  SLUICE_ALLOW_IPS="10.0.0.5:5432" SLUICE_ALLOW_IPS_MAX_BYTES="2097152" run _refusals "max-allow-ips-bytes 1048576"
  assert_output --partial "caps SLUICE_ALLOW_IPS_MAX_BYTES at 1048576"
}

@test "max-allow-ips-bytes: a non-numeric SLUICE_ALLOW_IPS_MAX_BYTES on the box is refused" {
  SLUICE_ALLOW_IPS="10.0.0.5:5432" SLUICE_ALLOW_IPS_MAX_BYTES="1MiB" run _refusals "max-allow-ips-bytes 1048576"
  assert_output --partial "requires a numeric SLUICE_ALLOW_IPS_MAX_BYTES"
}

@test "ceiling: a bare max-allow-ips directive with no arg is a no-op, not a refusal (empty != malformed)" {
  run _refusals "max-allow-ips"
  refute_output --partial "max-allow-ips needs a number"
  assert_output ""
}

@test "deny-ip: the top in-range address is refused, the adjacent block is not (exact CIDR boundary)" {
  SLUICE_ALLOW_IPS="10.0.0.255:5432" run _refusals "deny-ip 10.0.0.0/24"
  assert_output --partial "overlaps deny-ip"
  SLUICE_ALLOW_IPS="10.0.1.5:5432" run _refusals "deny-ip 10.0.0.0/24"
  refute_output --partial "deny-ip"
}
