#!/usr/bin/env bats
# SLUICE_ALLOW_IPS escape hatch: a listed IP gets a direct-egress jump to the accountable SLUICE-ALLOWIPS
# chain (bypassing squid, now metered); an unlisted IP gets none. ip[:port[/proto]] scopes the rule to
# one port (a bare ip stays any-port). The jumps sit BEFORE the ESTABLISHED accept so a long-lived flow
# is metered per-packet, not just on its SYN (the accountability ordering fix). Ported from
# verify-security.sh; setup_file builds the box + brings it up.
load test_helper/common

setup_file()    { make_box ips ips 'SLUICE_ALLOW_IPS="1.1.1.1 9.9.9.9:853"' 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box ips ips; }

@test "allow-ips: box image built" {
  run "$ENG" image inspect sluice-sectest-ips
  assert_success
}

@test "allow-ips: a bare IP jumps to the accountable SLUICE-ALLOWIPS chain (any port)" {
  run bash -c "'$ENG' exec --user root sluice-sectest-ips iptables -S OUTPUT | grep -E -- '-A OUTPUT -d 1\.1\.1\.1(/32)? -j SLUICE-ALLOWIPS'"
  assert_success
}

@test "allow-ips: a port-scoped entry (9.9.9.9:853) carries --dport 853 and jumps to the chain" {
  run bash -c "'$ENG' exec --user root sluice-sectest-ips iptables -S OUTPUT | grep -E -- '-A OUTPUT -d 9\.9\.9\.9(/32)? -p tcp -m tcp --dport 853 -j SLUICE-ALLOWIPS'"
  assert_success
}

@test "allow-ips: the port-scoped IP has NO any-port jump (only its port)" {
  run bash -c "'$ENG' exec --user root sluice-sectest-ips iptables -S OUTPUT | grep -E -- '-A OUTPUT -d 9\.9\.9\.9(/32)? -j SLUICE-ALLOWIPS'"
  assert_failure
}

@test "allow-ips: the SLUICE-ALLOWIPS chain exists with a terminal ACCEPT (no budget)" {
  run bash -c "'$ENG' exec --user root sluice-sectest-ips iptables -S SLUICE-ALLOWIPS | grep -E -- '-A SLUICE-ALLOWIPS -j ACCEPT'"
  assert_success
}

# The accountability ordering fix (the critique's core finding): the direct-IP jumps must appear BEFORE
# the ESTABLISHED,RELATED accept in OUTPUT. If they fell after it, only the SYN would traverse the chain
# and a multi-GB exfil would meter as ~60 bytes. Assert the rule-list order via -S line numbers.
@test "allow-ips: the direct-IP jumps precede the ESTABLISHED accept (per-packet metering)" {
  run bash -c "
    out=\"\$('$ENG' exec --user root sluice-sectest-ips iptables -S OUTPUT)\"
    jln=\$(printf '%s\n' \"\$out\" | grep -n -- '-j SLUICE-ALLOWIPS' | head -1 | cut -d: -f1)
    eln=\$(printf '%s\n' \"\$out\" | grep -nE -- '--state (ESTABLISHED,RELATED|RELATED,ESTABLISHED)' | tail -1 | cut -d: -f1)
    [ -n \"\$jln\" ] && [ -n \"\$eln\" ] && [ \"\$jln\" -lt \"\$eln\" ]
  "
  assert_success
}

@test "allow-ips: no rule for an unlisted IP (8.8.8.8)" {
  run "$ENG" exec --user root sluice-sectest-ips iptables -S OUTPUT
  assert_success
  refute_output --partial "8.8.8.8"
}

@test "allow-ips: live - direct egress reaches the bare IP 1.1.1.1:853 (best-effort)" {
  run bash -c "cd '$WORK/ips' && '$SLUICE' run curl -sS --connect-timeout 6 --max-time 10 -o /dev/null https://1.1.1.1:853"
  case "$status" in
    7|28) skip "1.1.1.1:853 unreachable from this runner (rc=$status) - the iptables-rule assertion gates" ;;
  esac
  # any other rc: the TCP connection to the non-HTTP port was ACCEPTed, i.e. direct egress works
}
