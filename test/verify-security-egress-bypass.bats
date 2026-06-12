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
