#!/usr/bin/env bats
# Acceptance: the egress + isolation guarantees on an empty box (CI gate). Ported from acceptance.sh.
# Engine-agnostic (SLUICE_ENGINE). setup_file builds the box once; each @test names one guarantee, so
# a failure points at the exact broken invariant (not a counter). Bump lives in acceptance-bump.bats.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"
  mkdir -p "$WORK/empty"
  printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/empty/sluice.config.sh"
  ( cd "$WORK/empty" && "$ROOT/bin/sluice" build ) >/dev/null 2>&1
  ( cd "$WORK/empty" && "$ROOT/bin/sluice" run true ) >/dev/null 2>&1   # bring the box up
}

teardown_file() { drop_box sluice-empty "$WORK/empty"; }

@test "empty box builds" {
  run "$ENG" image inspect sluice-empty
  assert_success
}

@test "allow: registry.npmjs.org reachable (spliced by SNI)" {
  egress_reaches "$WORK/empty" https://registry.npmjs.org/
}

@test "allow: github.com reachable (or on the active allowlist)" {
  egress_reaches "$WORK/empty" https://github.com/ && return 0
  # github's edge intermittently resets CI IPs; a denied host is never on the allowlist, so this holds.
  run bash -c "cd '$WORK/empty' && '$SLUICE' run grep -qx github.com /etc/squid/allowlist.txt"
  assert_success
}

@test "deny: example.com (HTTPS) blocked" {
  egress_blocked "$WORK/empty" https://example.com/
}

@test "deny: direct-IP https://1.1.1.1 blocked (no SNI)" {
  egress_blocked "$WORK/empty" https://1.1.1.1/
}

@test "deny: HTTP example.com blocked (by Host)" {
  egress_blocked "$WORK/empty" http://example.com/
}

@test "session is non-root (uid 1000)" {
  run bash -c "cd '$WORK/empty' && '$SLUICE' run id -u 2>/dev/null | tr -d '[:space:]'"
  assert_output "1000"
}

@test "IPv6 disabled" {
  run bash -c "cd '$WORK/empty' && '$SLUICE' run cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null | tr -d '[:space:]'"
  assert_output "1"
}
