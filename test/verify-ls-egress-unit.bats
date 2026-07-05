#!/usr/bin/env bats
# `ls --egress` blocked-count fail-closed (unit; no engine). box_blocked_count feeds the fleet
# overview's BLOCKED column; an unreadable in-box audit (pids-cgroup exhaustion blocks `exec`) must
# render unknown (empty -> ? / null), never a false all-clear 0 - the same class doctor/learn close.
load test_helper/common

setup() {
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/src"
  BIN="${src%/src}/bin/sluice"   # capture before sourcing: the prelude re-derives ROOT from $0
  # shellcheck disable=SC1090
  source "$src/00-prelude.sh"; source "$src/10-egress-helpers.sh"
}

@test "ls-egress: an unreadable in-box audit yields an empty (unknown) count, not 0" {
  _root_exec() { return 1; }
  run box_blocked_count sluice-x
  assert_success
  assert_output ""
}

@test "ls-egress: a readable audit with nothing denied still reports a real 0" {
  _root_exec() { return 0; }; blocked_hosts() { :; }
  run box_blocked_count sluice-x
  assert_success
  assert_output "0"
}

@test "ls-egress: a real denial still counts" {
  _root_exec() { return 0; }; blocked_hosts() { printf 'denied.example.io\n'; }
  run box_blocked_count sluice-x
  assert_success
  assert_output "1"
}

@test "ls-egress: the JSON render's defaulted-0 fail-open is gone (structural)" {
  # no render may default an empty (unknown) count to 0
  run grep -F 'blocks[$i]:-' "$BIN"
  assert_failure
}

@test "ls-egress: box_blocked_count consults _audit_readable before trusting a zero (structural)" {
  run bash -c "sed -n '/^box_blocked_count()/,/^}/p' '$BIN' | grep -q _audit_readable"
  assert_success
}
