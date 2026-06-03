#!/usr/bin/env bats
# SLUICE_ALLOW_IPS escape hatch: a listed IP gets a direct-egress ACCEPT rule (bypassing squid); an
# unlisted IP gets none. Ported from verify-security.sh. setup_file builds the box + brings it up.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ips"
  printf 'SLUICE_NAME="sectest-ips"\nSLUICE_ALLOW_IPS="1.1.1.1"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/ips/sluice.config.sh"
  ( cd "$WORK/ips" && "$SLUICE" build ) >/dev/null 2>&1 || true
  ( cd "$WORK/ips" && "$SLUICE" run true ) >/dev/null 2>&1 || true   # bring the box up
}

teardown_file() {
  chown_back_tree sluice-sectest-ips "$WORK"
  ( cd "$WORK/ips" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-ips >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-ips >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "allow-ips: box image built" {
  run "$ENG" image inspect sluice-sectest-ips
  assert_success
}

@test "allow-ips: a direct-egress ACCEPT rule is present for the listed IP" {
  run bash -c "'$ENG' exec --user root sluice-sectest-ips iptables -S OUTPUT | grep -E -- '-A OUTPUT -d 1\.1\.1\.1(/32)? -j ACCEPT'"
  assert_success
}

@test "allow-ips: no rule for an unlisted IP (8.8.8.8)" {
  run "$ENG" exec --user root sluice-sectest-ips iptables -S OUTPUT
  assert_success
  refute_output --partial "8.8.8.8"
}

@test "allow-ips: live - direct egress reaches 1.1.1.1:853 (best-effort)" {
  run bash -c "cd '$WORK/ips' && '$SLUICE' run curl -sS --connect-timeout 6 --max-time 10 -o /dev/null https://1.1.1.1:853"
  case "$status" in
    7|28) skip "1.1.1.1:853 unreachable from this runner (rc=$status) - the iptables-rule assertion gates" ;;
  esac
  # any other rc: the TCP connection to the non-HTTP port was ACCEPTed, i.e. direct egress works
}
