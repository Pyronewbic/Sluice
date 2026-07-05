#!/usr/bin/env bats
# Hard egress cap (unit; no engine). The in-box enforcement is a real xt_quota rule (covered by
# verify-security-hardcap.bats on a live box); here we cover the host-side gates that can run without
# Docker: the numeric/floor validation (fail closed) and the `max-hard-cap-bytes N` policy directive
# (an org mandating the ceiling). validate_egress_hard_caps is extracted from the built launcher;
# policy_evaluate is sourced and driven with a stubbed policy body.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  SLUICE_BIN="${src%/src}/bin/sluice"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"; source "$src/30-doctor-ls.sh"
}

_run_validate_caps() {  # $1 = SLUICE_EGRESS_HARD_CAP_BYTES, $2 = SLUICE_ALLOW_IPS_MAX_BYTES
  local t="$BATS_TEST_TMPDIR/vc.sh"
  {
    echo 'set -euo pipefail'
    echo 'die() { echo "[sluice] $*" >&2; exit 1; }'
    sed -n '/^validate_egress_hard_caps()/,/^}/p' "$SLUICE_BIN"
    echo 'validate_egress_hard_caps'
  } > "$t"
  SLUICE_EGRESS_HARD_CAP_BYTES="$1" SLUICE_ALLOW_IPS_MAX_BYTES="${2:-}" run bash "$t"
}

@test "hardcap validate: a non-numeric cap dies" {
  _run_validate_caps "lots"; assert_failure; assert_output --partial "must be a byte count"
}
@test "hardcap validate: below the 1 MiB floor dies (would brick the box at boot)" {
  _run_validate_caps "1000"; assert_failure; assert_output --partial ">= 1048576"
}
@test "hardcap validate: exactly 1 MiB passes" { _run_validate_caps "1048576"; assert_success; }
@test "hardcap validate: an unset cap passes untouched" { _run_validate_caps ""; assert_success; }
@test "allow-ips budget validate: a non-numeric budget dies" {
  _run_validate_caps "" "lots"; assert_failure; assert_output --partial "SLUICE_ALLOW_IPS_MAX_BYTES"
}
@test "allow-ips budget validate: a numeric budget passes" { _run_validate_caps "" "1000000"; assert_success; }

# --- policy: max-hard-cap-bytes N (source policy_evaluate; stub _policy_raw) -----------------------
@test "policy max-hard-cap-bytes: refuses a box that sets no hard cap" {
  POLICY_BODY="max-hard-cap-bytes 1048576"; _policy_raw() { printf '%s\n' "$POLICY_BODY"; }
  SLUICE_ALLOW_DOMAINS=""; SLUICE_ALLOW_IPS=""; unset SLUICE_EGRESS_HARD_CAP_BYTES
  policy_evaluate
  [[ "$_PEVAL_REFUSALS" == *"SLUICE_EGRESS_HARD_CAP_BYTES"* ]]
}
@test "policy max-hard-cap-bytes: refuses a cap above the ceiling" {
  POLICY_BODY="max-hard-cap-bytes 1048576"; _policy_raw() { printf '%s\n' "$POLICY_BODY"; }
  SLUICE_ALLOW_DOMAINS=""; SLUICE_ALLOW_IPS=""; SLUICE_EGRESS_HARD_CAP_BYTES=4194304
  policy_evaluate
  [[ "$_PEVAL_REFUSALS" == *"caps SLUICE_EGRESS_HARD_CAP_BYTES"* ]]
}
@test "policy max-hard-cap-bytes: a cap within the ceiling adds no refusal" {
  POLICY_BODY="max-hard-cap-bytes 4194304"; _policy_raw() { printf '%s\n' "$POLICY_BODY"; }
  SLUICE_ALLOW_DOMAINS=""; SLUICE_ALLOW_IPS=""; SLUICE_EGRESS_HARD_CAP_BYTES=2097152
  policy_evaluate
  [[ "$_PEVAL_REFUSALS" != *"HARD_CAP"* ]]
}
