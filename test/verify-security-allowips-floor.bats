#!/usr/bin/env bats
# Firewall defense-in-depth for the SLUICE_ALLOW_IPS floor (engine; Docker). The launcher's
# validate_allow_ips refuses a too-broad CIDR / IPv6 literal host-side - but the firewall must ALSO
# refuse it, so a bypassed launcher (e.g. a hand-baked /usr/local/share/sluice.config.sh) still can't
# open all direct egress. We rebake the in-box config with a poisoned SLUICE_ALLOW_IPS, re-run
# init-firewall.sh (it flushes + rebuilds), and assert: no ACCEPT for the broad/IPv6 entries, an ACCEPT
# for the legit one, and the box still ends default-DROP (a malformed entry must not crash the firewall).
#
# DOCKER-gated: this re-runs the in-container firewall, so it needs a real engine. macOS Docker Desktop
# diverges from CI (e.g. ip6tables); CI's security leg is the authoritative check.
load test_helper/common

# Build a box with a LEGIT narrow SLUICE_ALLOW_IPS (passes the launcher gate so the box builds at all).
setup_file()    { make_box ipsfloor ipsfloor 'SLUICE_ALLOW_IPS="9.9.9.9:853"' 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box ipsfloor ipsfloor; }

BOX=sluice-sectest-ipsfloor

@test "allow-ips-floor: box image built" {
  run "$ENG" image inspect "$BOX"; assert_success
}

# Poison the baked config with over-broad + IPv6 entries (alongside a legit one), re-run the firewall,
# and capture the resulting OUTPUT chain. The firewall reads /usr/local/share/sluice.config.sh.
_rerun_with_poisoned_config() {
  "$ENG" exec --user root "$BOX" sh -c '
    printf "SLUICE_ALLOW_IPS=\"0.0.0.0/1 128.0.0.0/1 10.0.0.0/4 2001:db8::1 7.7.7.7:7000\"\n" > /usr/local/share/sluice.config.sh
    /usr/local/bin/init-firewall.sh >/dev/null 2>&1
    iptables -S OUTPUT'
}

@test "allow-ips-floor: the firewall comes up default-DROP even with a poisoned (broad/IPv6) config" {
  run _rerun_with_poisoned_config
  assert_success                       # init-firewall did not abort on the malformed/IPv6 entry
  assert_line --index 0 "-P OUTPUT DROP"
}

@test "allow-ips-floor: NO direct-egress ACCEPT for the two-CIDR full cover or the broad /4" {
  run _rerun_with_poisoned_config
  assert_success
  refute_output --partial "-d 0.0.0.0/1"
  refute_output --partial "-d 128.0.0.0/1"
  refute_output --partial "-d 10.0.0.0/4"
}

@test "allow-ips-floor: NO ACCEPT for the IPv6 literal (IPv4-only; not fed to iptables)" {
  run _rerun_with_poisoned_config
  assert_success
  refute_output --partial "2001:db8"
}

@test "allow-ips-floor: the legit port-scoped entry alongside them is still ACCEPTed" {
  run _rerun_with_poisoned_config
  assert_success
  assert_output --partial "-d 7.7.7.7"   # the one good entry survives the poisoned siblings
}

# A port does NOT narrow the destination: 0.0.0.0/1:443 + 128.0.0.0/1:443 still cover the whole IPv4
# space on port 443, direct, bypassing squid. The firewall's floor/0.0.0.0 refusal must apply to the
# HOST part of an ip:port entry too, not just a bare CIDR - else the secondary layer is symmetric only
# on paper. (Regression for the PR2 review finding: the ip:port arm skipped the floor check.)
_rerun_with_poisoned_ipport_config() {
  "$ENG" exec --user root "$BOX" sh -c '
    printf "SLUICE_ALLOW_IPS=\"0.0.0.0/1:443 128.0.0.0/1:443 7.7.7.7:7000\"\n" > /usr/local/share/sluice.config.sh
    /usr/local/bin/init-firewall.sh >/dev/null 2>&1
    iptables -S OUTPUT'
}

@test "allow-ips-floor: a broad CIDR WITH a port is refused too - no full-cover ACCEPT on any port" {
  run _rerun_with_poisoned_ipport_config
  assert_success                       # one too-broad ip:port entry must not crash the firewall
  assert_line --index 0 "-P OUTPUT DROP"
  refute_output --partial "-d 0.0.0.0/1"     # not even scoped to :443
  refute_output --partial "-d 128.0.0.0/1"
}

@test "allow-ips-floor: the legit ip:port survives the broad-WITH-port poison siblings" {
  run _rerun_with_poisoned_ipport_config
  assert_success
  assert_output --partial "-d 7.7.7.7"       # the good entry still ACCEPTs; --dport 7000
}

# Restore the box's real config + firewall so a later suite sharing the image isn't left poisoned.
@test "allow-ips-floor: restore the box's real firewall state" {
  run "$ENG" exec --user root "$BOX" sh -c '
    printf "SLUICE_ALLOW_IPS=\"9.9.9.9:853\"\n" > /usr/local/share/sluice.config.sh
    /usr/local/bin/init-firewall.sh >/dev/null 2>&1
    iptables -S OUTPUT | head -1'
  assert_output "-P OUTPUT DROP"
}
