#!/usr/bin/env bats
# DNS query audit reader (unit; no engine). SLUICE_DNS_AUDIT=1 logs every query to a host-side-readable
# file; dns_rows parses it (pure awk), groups by immediate parent, and counts unique names - a DNS
# tunnel concentrates many unique labels under one parent. Stub _root_exec with a dnsmasq log fixture
# and assert the parse + the tunnel-flag JSON builder. The live in-box logging is a nightly/security case.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"
  container=box
}

_stub_dns_log() {
  _root_exec() { cat <<'LOG'
Jan  1 00:00:00 dnsmasq[7]: query[A] a1b2c3.tunnel.evil.com from 127.0.0.1
Jan  1 00:00:00 dnsmasq[7]: query[A] d4e5f6.tunnel.evil.com from 127.0.0.1
Jan  1 00:00:00 dnsmasq[7]: query[A] registry.npmjs.org from 127.0.0.1
Jan  1 00:00:00 dnsmasq[7]: query[A] "$(rm -rf)".evil.com from 127.0.0.1
LOG
  }
}

@test "dns_rows: groups by immediate parent with unique-name counts" {
  _stub_dns_log
  run dns_rows
  assert_success
  echo "$output" | awk -F'\t' '$1=="tunnel.evil.com" && $2=="2" && $3=="2"{f=1} END{exit f?0:1}'
}

@test "dns_rows: drops a non-hostname (injection) query name" {
  _stub_dns_log
  run dns_rows
  assert_success
  refute_output --partial "rm -rf"   # the crafted name with shell metachars is rejected by the charset gate
}

@test "dns json fields: totals + flags a tunnel parent over the threshold" {
  _stub_dns_log
  SLUICE_DNS_AUDIT=1; SLUICE_DNS_TUNNEL_THRESHOLD=2
  run _dns_json_fields
  assert_success
  assert_output --partial '"dns":{"queries":3,"unique":3'
  assert_output --partial '"parent":"tunnel.evil.com","unique":2'
}

@test "dns json fields: no flag when the threshold is above the tunnel's unique count" {
  _stub_dns_log
  SLUICE_DNS_AUDIT=1; SLUICE_DNS_TUNNEL_THRESHOLD=500
  run _dns_json_fields
  assert_success
  assert_output --partial '"flagged":[]'
}

@test "dns json fields: empty string when SLUICE_DNS_AUDIT is off" {
  unset SLUICE_DNS_AUDIT
  run _dns_json_fields
  assert_success
  assert_output ""
}
