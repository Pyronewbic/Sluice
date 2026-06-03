#!/usr/bin/env bats
# SLUICE_READONLY_ROOT=1: immutable rootfs, writable only where the box needs it (/home/sluice anon
# volume); the firewall + DNS still come up. Ported from verify-security.sh.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/ro"
  printf 'SLUICE_NAME="sectest-ro"\nSLUICE_RUN_CMD="bash"\n' > "$WORK/ro/sluice.config.sh"
  ( cd "$WORK/ro" && SLUICE_READONLY_ROOT=1 "$SLUICE" run true ) >/dev/null 2>&1 || true
}

teardown_file() {
  chown_back_tree sluice-sectest-ro "$WORK"
  ( cd "$WORK/ro" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-sectest-ro >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-ro >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "readonly: the rootfs is read-only" {
  run "$ENG" inspect sluice-sectest-ro --format '{{.HostConfig.ReadonlyRootfs}}'
  assert_output "true"
}

@test "readonly: a write to / is rejected" {
  run "$ENG" exec sluice-sectest-ro sh -c 'touch /evil'
  assert_failure
}

@test "readonly: /home/sluice is still writable (anon volume)" {
  run "$ENG" exec --user sluice sluice-sectest-ro sh -c 'touch /home/sluice/.p && rm /home/sluice/.p'
  assert_success
}

@test "readonly: the firewall/DNS came up under read-only (allowlist live)" {
  run "$ENG" exec sluice-sectest-ro sh -c 'grep -q registry.npmjs.org /etc/squid/allowlist.txt'
  assert_success
}
