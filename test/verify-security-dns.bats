#!/usr/bin/env bats
# DNS egress closure: name resolution is scoped to the egress allowlist. An allowlisted name forwards
# upstream (real IP); a NON-allowlisted name resolves to a dead sink (192.0.2.1) answered LOCALLY -
# never forwarded - so an agent can't tunnel exfil as DNS labels to an off-allowlist nameserver. The
# sink connection still hits squid via the 80/443 REDIRECT, so a blocked host is still logged and
# `sluice learn` can discover it (the discoverability the sink preserves vs. a hard refuse). Apps also
# can't reach the upstream resolver directly (firewall). SLUICE_DNS_OPEN=1 restores forward-all.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/dns"
  printf 'SLUICE_NAME="sectest-dns"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/dns/sluice.config.sh"
  ( cd "$WORK/dns" && "$SLUICE" build ) >/dev/null 2>&1 || true
  ( cd "$WORK/dns" && "$SLUICE" run true ) >/dev/null 2>&1 || true   # bring the box up
  # a blocked, non-allowlisted HTTPS attempt (scoped as a run, so `learn` sees it) - drives the
  # discoverability tests below.
  ( cd "$WORK/dns" && "$SLUICE" run curl -s --max-time 8 -o /dev/null https://pypi.org ) >/dev/null 2>&1 || true
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

@test "dns: an allowlisted base host resolves to a real IP (forwarded, not the sink)" {
  run "$ENG" exec --user sluice sluice-sectest-dns sh -c \
    'dig +short +time=4 +tries=2 A registry.npmjs.org 2>/dev/null | grep -E "^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$" | head -1'
  assert_output --regexp '[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+'
  refute_output --partial "192.0.2.1"
}

@test "dns: a non-allowlisted name resolves to the dead sink (answered locally, never forwarded -> no DNS-label exfil)" {
  run "$ENG" exec --user sluice sluice-sectest-dns sh -c \
    'dig +short +time=4 +tries=1 A exfil-canary.example.org 2>/dev/null | grep -E "^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$" | head -1'
  assert_output "192.0.2.1"
}

@test "dns: a blocked host still reaches squid and is logged (sink keeps it discoverable)" {
  run "$ENG" exec --user root sluice-sectest-dns grep -c 'ssl_sni=pypi.org' /var/log/squid/access.log
  assert_success
}

@test "dns: sluice learn --print discovers the blocked host (would be invisible under a hard refuse)" {
  run bash -c "cd '$WORK/dns' && '$SLUICE' learn --print 2>/dev/null"
  assert_output --partial "pypi.org"
}

@test "dns: uid 1000 cannot reach the upstream resolver directly (no bypass)" {
  up="$("$ENG" exec --user root sluice-sectest-dns sh -c 'head -n1 /run/sluice-dns-upstream' 2>/dev/null | tr -d '[:space:]')"
  [ -n "$up" ] || skip "no upstream recorded"
  # Query an ALLOWLISTED name straight at the upstream: only the firewall (uid 1000 -> resolver) can
  # stop it, so an ANSWER address here would mean the resolver path is reachable for exfil.
  run "$ENG" exec --user sluice sluice-sectest-dns sh -c \
    'dig +short +time=3 +tries=1 @'"$up"' A registry.npmjs.org 2>/dev/null | grep -E "^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$" || true'
  assert_output ""
}

@test "dns: SLUICE_DNS_OPEN=1 restores forward-all resolution (opt-in)" {
  mkdir -p "$WORK/dns-open"
  printf 'SLUICE_NAME="sectest-dns"\nSLUICE_DNS_OPEN=1\nSLUICE_RUN_CMD="bash"\n' > "$WORK/dns-open/sluice.config.sh"
  ( cd "$WORK/dns-open" && "$SLUICE" run true ) >/dev/null 2>&1   # rebuild (config changed) + up
  run "$ENG" exec --user sluice sluice-sectest-dns sh -c \
    'dig +short +time=4 +tries=2 A example.com 2>/dev/null | grep -E "^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$" | head -1'
  assert_output --regexp '[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+'
  refute_output --partial "192.0.2.1"
}
