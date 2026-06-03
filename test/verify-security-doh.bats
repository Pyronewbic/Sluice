#!/usr/bin/env bats
# DoH/DoT egress closure: an allowlisted DoH resolver is filtered out of the splice allowlist so squid
# terminates it. Ported from verify-security.sh's doh section - the one where the old harness silently
# false-passed (a missing assertion didn't fail). Each guarantee is its own @test now.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  mkdir -p "$WORK/doh"
  printf 'SLUICE_NAME="sectest-doh"\nSLUICE_ALLOW_DOMAINS="cloudflare-dns.com"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/doh/sluice.config.sh"
  ( cd "$WORK/doh" && "$ROOT/bin/sluice" run true ) >/dev/null 2>&1
}

teardown_file() {
  chown_back_tree sluice-sectest-doh "$WORK"
  ( cd "$WORK/doh" 2>/dev/null && "$ROOT/bin/sluice" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-doh >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-doh >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "doh: denylist baked in the box" {
  run "$ENG" exec sluice-sectest-doh sh -c 'test -s /etc/squid/doh-endpoints.txt'
  assert_success
}

@test "doh: an allowlisted DoH host is filtered out of the splice allowlist" {
  run "$ENG" exec sluice-sectest-doh sh -c '! grep -qx cloudflare-dns.com /etc/squid/allowlist.txt'
  assert_success
}

@test "doh: an allowlisted DoH resolver is blocked (live)" {
  run "$ENG" exec --user sluice sluice-sectest-doh curl -s -o /dev/null --max-time 8 https://cloudflare-dns.com/
  assert_failure
}

@test "doh: SLUICE_ALLOW_DOH=1 keeps the DoH host on the allowlist (opt-in)" {
  # FRESH dir - the box chowns the project to uid 1000 on Linux, so rewriting in place would EACCES.
  mkdir -p "$WORK/doh-optin"
  printf 'SLUICE_NAME="sectest-doh"\nSLUICE_ALLOW_DOMAINS="cloudflare-dns.com"\nSLUICE_ALLOW_DOH=1\nSLUICE_RUN_CMD="bash"\n' > "$WORK/doh-optin/sluice.config.sh"
  ( cd "$WORK/doh-optin" && "$SLUICE" run true ) >/dev/null 2>&1   # rebuild (config changed) + up
  run "$ENG" exec sluice-sectest-doh sh -c 'grep -qx cloudflare-dns.com /etc/squid/allowlist.txt'
  assert_success
}
