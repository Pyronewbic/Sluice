#!/usr/bin/env bats
# Container hardening: no-new-privileges, a pids-limit, a narrowed cap bounding set (net_admin kept,
# sys_admin/mknod dropped), zero effective caps for the session, and no in-box sudo. Ported from
# verify-security.sh. setup_file builds + brings up an empty box.
load test_helper/common

setup_file()    { make_box harden harden 'SLUICE_RUN_CMD="bash"'; }
teardown_file() { destroy_box harden harden; }

@test "harden: no-new-privileges is set" {
  run "$ENG" inspect sluice-sectest-harden --format '{{.HostConfig.SecurityOpt}}'
  assert_output --partial "no-new-privileges"
}

@test "harden: the default pids-limit is 4096" {
  run "$ENG" inspect sluice-sectest-harden --format '{{.HostConfig.PidsLimit}}'
  assert_output "4096"   # the documented default - a regression to 0/unset must fail, not pass on >0
}

# Custom resource caps are actually applied to the box (not just echoed by doctor). Own box so the
# harden box keeps the default above.
@test "harden: SLUICE_PIDS_LIMIT and SLUICE_MEMORY are applied to the box" {
  local d; d="$(mktemp -d)"; mkdir -p "$d/cap"
  printf 'SLUICE_NAME="sectest-harden-cap"\nSLUICE_PIDS_LIMIT="64"\nSLUICE_MEMORY="256m"\nSLUICE_RUN_CMD="bash"\n' > "$d/cap/sluice.config.sh"
  ( cd "$d/cap" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  run "$ENG" inspect sluice-sectest-harden-cap --format '{{.HostConfig.PidsLimit}} {{.HostConfig.Memory}}'
  assert_output "64 268435456"   # 256m in bytes
  nuke_tree sluice-sectest-harden-cap "$d"
  "$ENG" rm -f -v sluice-sectest-harden-cap >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-sectest-harden-cap >/dev/null 2>&1 || true
}

@test "harden: the session has zero effective caps" {
  run "$ENG" exec --user sluice sluice-sectest-harden sh -c 'grep CapEff /proc/self/status | tr -d "\t "'
  assert_output "CapEff:0000000000000000"
}

@test "harden: cap bounding set narrowed (net_admin kept, sys_admin/mknod dropped)" {
  local cb na sa mk
  cb="$("$ENG" exec --user root sluice-sectest-harden sh -c 'grep CapBnd /proc/self/status | awk "{print \$2}"' 2>/dev/null)"
  na=$(( 0x${cb:-0} & 0x1000 )); sa=$(( 0x${cb:-0} & 0x200000 )); mk=$(( 0x${cb:-0} & 0x8000000 ))
  [ "$na" -ne 0 ] && [ "$sa" -eq 0 ] && [ "$mk" -eq 0 ] || { echo "CapBnd=0x${cb}"; false; }
}

@test "harden: no in-box sudo (privilege-escalation primitive removed)" {
  run "$ENG" exec sluice-sectest-harden sh -c 'command -v sudo || true'
  refute_output --partial "sudo"
}
