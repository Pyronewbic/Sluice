#!/usr/bin/env bats
# Egress receipt + budget: a run-default session persists a durable receipt (hosts reached/blocked +
# bytes) to the state dir, and SLUICE_EGRESS_MAX_BYTES makes `sluice egress` exit non-zero over the
# cap - a CI gate that bounds laundering through an allowed host. setup_file does one run-default that
# reaches an allowlisted base host (so there's real egress), then the box stays up for the gate tests.
load test_helper/common

RCPT() { echo "$WORK/state/sluice/sectest-receipt/egress-receipt.json"; }
ELOG() { echo "$WORK/state/sluice/sectest-receipt/egress-log.jsonl"; }

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/r"
  export XDG_STATE_HOME="$WORK/state"
  printf 'SLUICE_NAME="sectest-receipt"\nSLUICE_RUN_CMD="curl -s -o /dev/null https://registry.npmjs.org/ || true"\n' > "$WORK/r/sluice.config.sh"
  ( cd "$WORK/r" && XDG_STATE_HOME="$WORK/state" "$SLUICE" ) >/dev/null 2>&1 || true   # run-default: build + egress + receipt
}

teardown_file() { destroy_box receipt r; }   # XDG_STATE_HOME is under WORK, so nuke_tree clears it too

@test "receipt: box image built" {
  run "$ENG" image inspect sluice-sectest-receipt
  assert_success
}

@test "receipt: egress-receipt.json written to the state dir on run exit" {
  assert_file_exist "$WORK/state/sluice/sectest-receipt/egress-receipt.json"
}

@test "receipt: records the box and a totals object" {
  run cat "$(RCPT)"
  assert_success
  assert_output --partial '"box":"sluice-sectest-receipt"'
  assert_output --partial '"totals":'
}

@test "receipt: valid JSON with a hosts array" {
  run bash -c "jq -e '.hosts | type == \"array\"' '$(RCPT)'"
  assert_success
}

@test "egress budget: a tiny SLUICE_EGRESS_MAX_BYTES makes 'sluice egress' exit non-zero" {
  run bash -c "cd '$WORK/r' && SLUICE_EGRESS_MAX_BYTES=1 '$SLUICE' egress"
  assert_failure
  assert_output --partial "budget EXCEEDED"
}

@test "egress budget: a large cap passes (exit 0)" {
  run bash -c "cd '$WORK/r' && SLUICE_EGRESS_MAX_BYTES=999999999 '$SLUICE' egress"
  assert_success
}

@test "egress budget: --json reports over_budget over a tiny cap" {
  run bash -c "cd '$WORK/r' && SLUICE_EGRESS_MAX_BYTES=1 '$SLUICE' egress --json"
  assert_failure
  assert_output --partial '"over_budget":true'
}

# --- evidence-grade receipts -------------------------------------------------------------------

@test "receipt: snapshot carries the versioned schema id" {
  run cat "$(RCPT)"
  assert_output --partial '"schema":"sluice.egress/v1"'
}

@test "receipt: an append-only JSONL audit log is written with a hash-chained record" {
  assert_file_exist "$(ELOG)"
  run bash -c "head -1 '$(ELOG)' | jq -e '.schema==\"sluice.egress/v1\" and (.self|type==\"string\") and (.prev|type==\"string\")'"
  assert_success
}

@test "egress --verify: an untampered chain verifies (exit 0)" {
  run bash -c "cd '$WORK/r' && XDG_STATE_HOME='$WORK/state' '$SLUICE' egress --verify"
  assert_success
  assert_output --partial "hash chain intact"
}

@test "egress --export: emits the JSONL audit log" {
  run bash -c "cd '$WORK/r' && XDG_STATE_HOME='$WORK/state' '$SLUICE' egress --export | jq -e '.box==\"sluice-sectest-receipt\"'"
  assert_success
}

@test "egress --verify: a tampered record is detected (exit non-zero)" {
  cp "$(ELOG)" "$(ELOG).bak"
  # alter a byte inside record 1's signed body, leaving its self/prev intact -> self-hash must mismatch
  sed '1s/registry\.npmjs\.org/registry.npmjs.evil/' "$(ELOG).bak" > "$(ELOG)"
  run bash -c "cd '$WORK/r' && XDG_STATE_HOME='$WORK/state' '$SLUICE' egress --verify"
  mv "$(ELOG).bak" "$(ELOG)"   # restore before other tests read it
  assert_failure
  assert_output --partial "TAMPERED"
}
