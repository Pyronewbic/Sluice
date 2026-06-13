#!/usr/bin/env bats
# Egress receipt chain + box-gone record (unit; no engine). The hash-chained audit log and its
# `egress --verify` are pure shell (state dir + sha256, no box), so the tamper matrix runs in the
# no-Docker lane: intact verifies, a body byte-flip trips the self-hash branch, and a delete or reorder
# trips the prev-link branch (the part that makes it a chain, not per-record checksums). Also asserts a
# box gone before capture records an explicit "unavailable" instead of looking like a clean zero-egress
# run. (verify-security-receipt.bats keeps one live-box smoke that the real run-default chain verifies.)
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"
  source "$src/20-lock-sbom-scan.sh"; source "$src/80-learn.sh"
  export XDG_STATE_HOME; XDG_STATE_HOME="$(mktemp -d)"
  slug="utrcpt"; container="sluice-utrcpt"; SLUICE_ALLOW_DOMAINS=""
  LOG="$XDG_STATE_HOME/sluice/$slug/egress-log.jsonl"
}
teardown() { rm -rf "$XDG_STATE_HOME"; }

# append one chained receipt record reaching host $1
_rec() { local TAB; TAB="$(printf '\t')"; _persist_receipt "$(printf 'reached%s%s%s1%s100' "$TAB" "$1" "$TAB" "$TAB")" ok; }

@test "receipt-chain: three records build a chain that verifies intact" {
  _rec a.example.com; _rec b.example.com; _rec c.example.com
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 3 ]
  run cmd_egress_verify
  assert_success
  assert_output --partial "hash chain intact"
}

@test "receipt-chain: a byte flip in a record body trips the self-hash branch" {
  _rec a.example.com; _rec b.example.com
  sed -i.bak '1s/a\.example\.com/a.evil.com/' "$LOG"
  run cmd_egress_verify
  assert_failure
  assert_output --partial "self-hash"
}

@test "receipt-chain: deleting a middle record trips the prev-link branch" {
  _rec a.example.com; _rec b.example.com; _rec c.example.com
  sed -i.bak '2d' "$LOG"   # record 3's prev no longer matches record 1's self
  run cmd_egress_verify
  assert_failure
  assert_output --partial "prev-link"
}

@test "receipt-chain: reordering records trips the prev-link branch" {
  _rec a.example.com; _rec b.example.com
  { sed -n '2p' "$LOG"; sed -n '1p' "$LOG"; } > "$LOG.r"; mv "$LOG.r" "$LOG"
  run cmd_egress_verify
  assert_failure
  assert_output --partial "prev-link"
}

# A forged record appended to the tail WITHOUT a trailing newline used to be invisible: bash `read`
# returns non-zero at EOF on a missing newline, so the old loop dropped the last record and verify
# reported intact (rc 0) while --export shipped it. The fix processes a non-empty final line too.
@test "receipt-chain: a forged final record with no trailing newline is caught as TAMPERED" {
  _rec a.example.com; _rec b.example.com
  local last_self; last_self="$(sed -n 's/.*,"self":"\([0-9a-f]*\)"}$/\1/p' "$LOG" | tail -1)"
  # Append attacker JSON (bogus self) with NO trailing newline - the unterminated tail the bug hid.
  printf '{"schema":"sluice.egress/v1","host":"evil.com","prev":"%s","self":"deadbeef"}' "$last_self" >> "$LOG"
  run cmd_egress_verify
  assert_failure
  assert_output --partial "TAMPERED"
}

# A trailing (or interspersed) blank line is not a record - it must not be hashed into a false
# TAMPERED. verify skips empty lines and still reports the real chain intact.
@test "receipt-chain: a trailing blank line does not trip a false TAMPERED" {
  _rec a.example.com; _rec b.example.com
  printf '\n' >> "$LOG"   # blank trailing line; the chain itself is untouched
  run cmd_egress_verify
  assert_success
  assert_output --partial "hash chain intact"
}

@test "receipt: a box gone before capture records an explicit 'unavailable' (not silent zero-egress)" {
  _persist_receipt "" unavailable
  run bash -c "tail -1 '$LOG' | jq -e '.status==\"unavailable\" and (.totals.reached==0)'"
  assert_success
}

# Box UP but the in-box audit can't be read (uid 1000 exhausted the pids cgroup so `exec` can't fork):
# empty rows must record 'unavailable', not look like a clean zero-egress run.
@test "receipt: box up + unreadable audit records 'unavailable' (pids-cgroup blind)" {
  running() { return 0; }; egress_rows() { :; }; _audit_readable() { return 1; }
  run show_egress_receipt
  assert_success
  run bash -c "tail -1 '$LOG' | jq -e '.status==\"unavailable\"'"
  assert_success
}

@test "egress: an unreadable in-box audit fails the byte gate closed (non-zero), not a silent zero" {
  running() { return 0; }; egress_rows() { :; }; _audit_readable() { return 1; }
  run cmd_egress
  assert_failure
}

# cmd_egress_verify is a sourced function (no box), so capture its --json stdout via `run` and pipe
# $output to jq - bash -c can't see the sourced function.
@test "egress --verify --json: an intact chain reports verified:true records:N, exit 0" {
  _rec a.example.com; _rec b.example.com; _rec c.example.com
  run cmd_egress_verify --json
  assert_success
  jq -e '.verified==true and .records==3 and .broken_line==null and .reason==null' <<<"$output"
}

@test "egress --verify --json: a body byte-flip reports verified:false self-hash + broken_line, non-zero" {
  _rec a.example.com; _rec b.example.com
  sed -i.bak '1s/a\.example\.com/a.evil.com/' "$LOG"
  run cmd_egress_verify --json
  assert_failure
  jq -e '.verified==false and .reason=="self-hash" and .broken_line==1' <<<"$output"
}

@test "egress --verify --json: a dropped middle record reports verified:false prev-link, non-zero" {
  _rec a.example.com; _rec b.example.com; _rec c.example.com
  sed -i.bak '2d' "$LOG"   # record 3's prev no longer matches record 1's self
  run cmd_egress_verify --json
  assert_failure
  jq -e '.verified==false and .reason=="prev-link" and (.broken_line|type=="number")' <<<"$output"
}
