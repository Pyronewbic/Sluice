#!/usr/bin/env bats
# SLUICE_READONLY_ROOT=1: immutable rootfs, writable only where the box needs it (/home/sluice anon
# volume); the firewall + DNS still come up. Ported from verify-security.sh.
load test_helper/common

# SLUICE_READONLY_ROOT lives in the config (not the warm env) so make_box applies it at boot.
setup_file()    { make_box ro ro 'SLUICE_READONLY_ROOT=1' 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box ro ro; }

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

@test "readonly: system tmpfs are not world-writable (no 1777 default) - uid 1000 can't fill them" {
  # /run + /var/log/squid are root/squid-owned 0755; uid 1000 must be unable to create files there
  # (a 1777 default would let it fill the squid log tmpfs and starve the access log).
  run "$ENG" exec --user sluice sluice-sectest-ro sh -c 'touch /run/evil 2>/dev/null || touch /var/log/squid/evil 2>/dev/null'
  assert_failure
}

@test "readonly: /tmp is still usable world scratch (sticky 1777)" {
  run "$ENG" exec --user sluice sluice-sectest-ro sh -c 'touch /tmp/.p && rm /tmp/.p'
  assert_success
}
