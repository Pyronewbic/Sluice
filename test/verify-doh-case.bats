#!/usr/bin/env bats
# DoH denylist matching (unit; no engine). Two evasions of the `sluice learn` DoH filter:
#  - case: the SNI regex accepts uppercase and squid/dnsmasq match case-insensitively, so DNS.GOOGLE
#    must still hit the lowercase denylist.
#  - wildcard coverage: a `.parent` collapse the user accepts (e.g. .adguard.com) must be refused when it
#    COVERS a listed DoH host (dns.adguard.com), or it re-allows the resolver via splice.
# drop_doh (entrypoint, boot) carries the identical guards.
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

@test "doh-cover: a .parent wildcard covering an exact DoH host is rejected (.adguard.com)" { run doh_listed .adguard.com; assert_success; }
@test "doh-cover: a .parent wildcard covering an exact DoH host is rejected (.mullvad.net)" { run doh_listed .mullvad.net; assert_success; }
@test "doh-cover: the exact non-resolver parent host is still allowed (adguard.com)" { run doh_listed adguard.com; assert_failure; }
@test "doh-cover: an unrelated wildcard is not a DoH endpoint (.example.com)" { run doh_listed .example.com; assert_failure; }
