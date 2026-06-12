#!/usr/bin/env bats
# Central-policy pure helpers (unit; no engine). CIDR membership for deny-ip and the deny-host
# wildcard matcher are extracted from the built launcher and exercised in isolation - they decide
# what an org policy refuses, so they get direct coverage.
load test_helper/common

setup() {
  # Pull just the pure function defs out of bin/sluice (don't source it - that runs the whole CLI).
  eval "$(sed -n '/^_ip2int()/,/^}/p; /^_ip_in_cidr()/,/^}/p; /^_policy_denied_host()/,/^}/p; /^_allow_covers_denied()/,/^}/p' "$ROOT/bin/sluice")"
}

@test "cidr: an IP inside a /8 matches" { run _ip_in_cidr 10.0.0.5 10.0.0.0/8; assert_success; }
@test "cidr: an IP outside a /8 does not match" { run _ip_in_cidr 11.0.0.5 10.0.0.0/8; assert_failure; }
@test "cidr: a /24 boundary is respected" {
  run _ip_in_cidr 192.168.1.9 192.168.1.0/24; assert_success
  run _ip_in_cidr 192.168.2.9 192.168.1.0/24; assert_failure
}
@test "cidr: a bare IP matches only itself" {
  run _ip_in_cidr 1.2.3.4 1.2.3.4; assert_success
  run _ip_in_cidr 1.2.3.5 1.2.3.4; assert_failure
}

@test "deny-host: an exact host is denied" { run _policy_denied_host pastebin.com "pastebin.com gist.github.com"; assert_success; }
@test "deny-host: a leading-dot wildcard denies subdomains" { run _policy_denied_host x.pastebin.com ".pastebin.com"; assert_success; }
@test "deny-host: an unrelated host is not denied" { run _policy_denied_host safe.example.com "pastebin.com"; assert_failure; }

# An allow .parent wildcard that covers a denied host must be caught (else local config defeats the deny).
@test "allow-covers-deny: a .parent allow wildcard covering a denied host is flagged" { run _allow_covers_denied .githubusercontent.com "gist.githubusercontent.com"; assert_success; }
@test "allow-covers-deny: an exact allow host is never flagged (only wildcards over-admit)" { run _allow_covers_denied raw.githubusercontent.com "gist.githubusercontent.com"; assert_failure; }
@test "allow-covers-deny: a wildcard not covering the deny is not flagged" { run _allow_covers_denied .example.com "gist.githubusercontent.com"; assert_failure; }
@test "allow-covers-deny: a broad wildcard covering a deny-wildcard token is flagged" { run _allow_covers_denied .com ".evil.com"; assert_success; }
