#!/usr/bin/env bats
# SLUICE_ALLOW_IPS accountability readers (unit; no engine). The direct-egress escape hatch is now
# routed through a SLUICE-ALLOWIPS iptables chain so its per-entry counters are visible. These readers
# parse `iptables -nvxL` output (pure awk); stub _root_exec with a fixture and assert the parse:
# per-entry rows (dport + dst-only), the firewall policy-DROP total, the budget-DROP counter, and the
# JSON fragment builder. The live in-box metering is covered by verify-security-allowips.bats.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"
  container=box
}

_stub_output_chain() {
  _root_exec() { cat <<'IPT'
Chain OUTPUT (policy DROP 12 packets, 800 bytes)
    pkts      bytes target     prot opt in     out     source               destination
      10      840 SLUICE-ALLOWIPS  tcp  --  *      *       0.0.0.0/0            10.0.0.5             tcp dpt:5432
       3      120 SLUICE-ALLOWIPS  all  --  *      *       0.0.0.0/0            10.0.0.6
      50     4000 ACCEPT     all  --  *      *       0.0.0.0/0            127.0.0.0/8
IPT
  }
}

@test "allowips_rows: parses per-entry counters (dport + dst-only)" {
  _stub_output_chain
  run allowips_rows
  assert_success
  echo "$output" | awk -F'\t' '$1=="10.0.0.5:5432" && $2=="10" && $3=="840"{a=1} $1=="10.0.0.6" && $2=="3" && $3=="120"{b=1} END{exit (a&&b)?0:1}'
}

@test "fw_dropped: parses the OUTPUT policy-DROP total" {
  _stub_output_chain
  run fw_dropped
  assert_success
  echo "$output" | awk -F'\t' '$1=="12" && $2=="800"{f=1} END{exit f?0:1}'
}

@test "allowips_dropped: reports the SLUICE-ALLOWIPS budget DROP packet count" {
  _root_exec() { cat <<'IPT'
Chain SLUICE-ALLOWIPS (2 references)
    pkts      bytes target     prot opt in     out     source               destination
       5      300 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            quota: 1048576 bytes
       2      120 DROP       all  --  *      *       0.0.0.0/0            0.0.0.0/0
IPT
  }
  run allowips_dropped
  assert_success
  assert_output "2"
}

@test "allowips_dropped: empty when there is no DROP rule (no budget)" {
  _root_exec() { cat <<'IPT'
Chain SLUICE-ALLOWIPS (1 references)
    pkts      bytes target     prot opt in     out     source               destination
       5      300 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0
IPT
  }
  run allowips_dropped
  assert_success
  assert_output ""
}

@test "allowips json fields: builds allow_ips[] + fw_dropped{} when SLUICE_ALLOW_IPS is set" {
  _stub_output_chain
  _squid_log() { :; }
  SLUICE_ALLOW_IPS="10.0.0.5:5432 10.0.0.6"
  run _allowips_json_fields
  assert_success
  assert_output --partial '"allow_ips":[{"entry":"10.0.0.5:5432","packets":10,"bytes":840}'
  assert_output --partial '"fw_dropped":{"packets":12,"bytes":800}'
  assert_output --partial '"denied_ip_requests":0'
}

@test "allowips json fields: drop accountability stays on when SLUICE_ALLOW_IPS is unset" {
  unset SLUICE_ALLOW_IPS
  _stub_output_chain
  _squid_log() { printf '1752709000.123 172.17.0.2 NONE_NONE/000 CONNECT 1.1.1.1:443 ssl_sni=- tx=0 rx=0\n'; }
  run _allowips_json_fields
  assert_success
  assert_output ',"fw_dropped":{"packets":12,"bytes":800},"denied_ip_requests":1'
}

@test "denied_ip_requests: counts denied raw-IP targets, ignores hostname denials + successes" {
  _squid_log() { cat <<'LOG'
1752709000.123 172.17.0.2 NONE_NONE/000 CONNECT 1.1.1.1:443 ssl_sni=- tx=0 rx=0
1752709001.123 172.17.0.2 TCP_DENIED/403 GET http://9.9.9.9/probe ssl_sni=- tx=0 rx=0
1752709002.123 172.17.0.2 NONE_NONE/000 CONNECT blocked.example:443 ssl_sni=blocked.example tx=0 rx=0
1752709003.123 172.17.0.2 TCP_TUNNEL/200 CONNECT 8.8.8.8:443 ssl_sni=- tx=100 rx=200
LOG
  }
  run denied_ip_requests
  assert_success
  assert_output "2"
}
