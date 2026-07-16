#!/usr/bin/env bats
# Forward-proxy CONNECT bypass closure (engine). squid binds a forward-proxy port (3128) it requires,
# but a CONNECT there is unfiltered - it would blind-tunnel raw TCP to ANY ip:port, defeating the SNI
# filter, the direct-IP block, the non-80/443 DROP, and DNS scoping at once. squid denies localport
# 3128 and the firewall REJECTs every non-squid uid to it. Legit HTTPS (transparent intercept on 3130)
# must keep working.
load test_helper/common

setup_file() { make_box egbypass egbypass 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box egbypass egbypass; }

@test "egress-bypass: box image built" {
  run "$ENG" image inspect sluice-sectest-egbypass
  assert_success
}

@test "egress-bypass: forward-proxy CONNECT to a raw IP is refused" {
  run bash -c "cd '$WORK/egbypass' && '$SLUICE' run curl -sS --max-time 8 -o /dev/null -x 127.0.0.1:3128 https://1.1.1.1"
  assert_failure
}

@test "egress-bypass: forward-proxy CONNECT to an allowlisted host by name is also refused" {
  # Even an allowlisted host must not be reachable via the explicit proxy - legit traffic uses the
  # transparent intercept, never 3128. This proves the port is dead, not just IP-filtered.
  run bash -c "cd '$WORK/egbypass' && '$SLUICE' run curl -sS --max-time 8 -o /dev/null -x 127.0.0.1:3128 https://registry.npmjs.org"
  assert_failure
}

@test "egress-bypass: legit HTTPS via the transparent intercept still reaches an allowlisted base host" {
  run egress_reaches "$WORK/egbypass" https://registry.npmjs.org
  assert_success
}

@test "egress-bypass: a denied raw-IP attempt is ledgered, not just dropped" {
  # The transparent intercept denies a no-SNI raw-IP CONNECT; the ledger must count it even though
  # the hostname rows skip IP literals (learn must never propose one).
  ( cd "$WORK/egbypass" && "$SLUICE" run curl -sS --max-time 8 -o /dev/null https://1.1.1.1 ) || true
  run bash -c "cd '$WORK/egbypass' && '$SLUICE' egress --json | jq -e '.denied_ip_requests >= 1'"
  assert_success
}

# The fail-closed boot self-test (init-firewall.sh) asserts -P OUTPUT DROP (v4 + v6) and exits 1 on a
# non-DROP policy; entrypoint runs it under set -e before "[sluice] ready", so a failed self-test means
# no box. These assert the guarantee it enforces holds on the live box - a regression that weakened the
# default-DROP policy (or dropped the assertion) fails here even though legit traffic still flows.
@test "egress-bypass: the box's default OUTPUT policy is DROP (IPv4 default-DROP holds)" {
  run "$ENG" exec --user root sluice-sectest-egbypass sh -c 'iptables -S OUTPUT | head -1'
  assert_output "-P OUTPUT DROP"
}

@test "egress-bypass: IPv6 egress is closed (disabled v6 stack or -P OUTPUT DROP)" {
  # init-firewall closes v6 EITHER via the disable_ipv6 sysctl (no v6 stack to filter) OR an ip6tables
  # OUTPUT DROP when the stack is up - it guards its own assertion the same way. A runner with v6 fully
  # off returns EMPTY ip6tables output (that's closed, not a regression), so assert the disjunction.
  run "$ENG" exec --user root sluice-sectest-egbypass sh -c '
    [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 1 ] && exit 0
    [ "$(ip6tables -S OUTPUT 2>/dev/null | head -1)" = "-P OUTPUT DROP" ] && exit 0
    exit 1'
  assert_success
}
