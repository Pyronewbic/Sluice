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

@test "receipt: a box gone before capture records an explicit 'unavailable' (not silent zero-egress)" {
  _persist_receipt "" unavailable
  run bash -c "tail -1 '$LOG' | jq -e '.status==\"unavailable\" and (.totals.reached==0)'"
  assert_success
}
