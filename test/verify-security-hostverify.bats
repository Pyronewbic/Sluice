#!/usr/bin/env bats
# Forged-Host plaintext-HTTP exfil closure (engine). squid intercepts tcp/80 and authorizes by the
# client-supplied Host header. Without host_verify_strict a uid-1000 process can send
# `Host: <allowlisted>` while connecting to an ARBITRARY IP and squid forwards there - data exfil past
# the by-domain gate, no caps and no DNS needed. host_verify_strict on (squid.conf) makes squid refuse
# a Host that doesn't resolve to the connected IP. Legit allowlisted HTTP (Host matches) must still work.
load test_helper/common

setup_file() { make_box hostverify hostverify 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box hostverify hostverify; }

@test "hostverify: box image built" {
  run "$ENG" image inspect sluice-sectest-hostverify
  assert_success
}

@test "hostverify: forged allowlisted Host to a non-allowlisted IP on :80 is refused" {
  # Connect to 1.1.1.1:80 but send Host: registry.npmjs.org (allowlisted). -f so squid's 409 host-verify
  # denial is a failure; a real 2xx/3xx would mean squid forwarded to the bogus IP (the bypass).
  run bash -c "cd '$WORK/hostverify' && '$SLUICE' run curl -fsS --max-time 8 -o /dev/null --resolve registry.npmjs.org:80:1.1.1.1 http://registry.npmjs.org/"
  assert_failure
}

@test "hostverify: legit allowlisted HTTP (Host matches the connected host) still works" {
  run egress_reaches "$WORK/hostverify" http://registry.npmjs.org/
  assert_success
}

@test "hostverify: host_verify_strict is set in the running box's squid config" {
  run "$ENG" exec --user root sluice-sectest-hostverify sh -c 'grep -c "^host_verify_strict on" /etc/squid.conf'
  assert_success
  assert_output 1
}
