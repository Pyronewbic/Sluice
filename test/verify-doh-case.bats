#!/usr/bin/env bats
# DoH denylist case-insensitivity (unit; no engine). The SNI regex accepts uppercase and squid
# dstdomain / dnsmasq match domains case-insensitively, so a mixed-case resolver name (DNS.GOOGLE) must
# still hit the lowercase denylist - otherwise `sluice learn` would write it and open a DoH tunnel that
# bypasses the SNI filter. drop_doh (entrypoint, boot) carries the identical lowercase guard.
load test_helper/common

setup() {
  eval "$(sed -n '/^doh_listed()/,/^}/p' "$ROOT/bin/sluice")"
  CORE="$ROOT/core"
}

@test "doh-case: lowercase dns.google is a DoH endpoint" { run doh_listed dns.google; assert_success; }
@test "doh-case: mixed-case DNS.GOOGLE still matches" { run doh_listed DNS.GOOGLE; assert_success; }
@test "doh-case: uppercase ONE.ONE.ONE.ONE still matches" { run doh_listed ONE.ONE.ONE.ONE; assert_success; }
@test "doh-case: a subdomain of a .wildcard endpoint matches case-insensitively" { run doh_listed FOO.Cloudflare-DNS.com; assert_success; }
@test "doh-case: a normal host is not a DoH endpoint" { run doh_listed API.Example.com; assert_failure; }
