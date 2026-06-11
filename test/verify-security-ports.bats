#!/usr/bin/env bats
# SLUICE_PORTS publishes to host loopback ONLY (127.0.0.1) - a regression to 0.0.0.0 would expose the
# box to the LAN, breaking the inbound-surface guarantee (THREAT_MODEL). Assert the host port binding.
load test_helper/common

setup_file()    { make_box ports ports 'SLUICE_PORTS="8080"' 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box ports ports; }

@test "ports: 8080 is published on 127.0.0.1, never 0.0.0.0" {
  run "$ENG" inspect sluice-sectest-ports --format '{{json .HostConfig.PortBindings}}'
  assert_output --partial '"8080/tcp"'
  assert_output --partial '"HostIp":"127.0.0.1"'
  refute_output --partial '0.0.0.0'
}
