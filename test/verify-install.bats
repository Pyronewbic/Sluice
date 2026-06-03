#!/usr/bin/env bats
# install.sh smoke (no Docker, PR gate): symlink the CLI into a throwaway HOME and confirm the
# installed `sluice` resolves + runs. Ported from verify-install.sh.
load test_helper/common

setup_file() {
  export TMP; TMP="$(mktemp -d)"
  HOME="$TMP" SLUICE_HOME="$TMP/share/sluice" sh "$ROOT/install.sh" > "$TMP/install.log" 2>&1
  echo "$?" > "$TMP/install.rc"
}

teardown_file() { rm -rf "$TMP"; }

@test "install.sh ran" {
  run cat "$TMP/install.rc"
  assert_output "0"
}

@test "symlink points at the checkout's bin/sluice" {
  local link="$TMP/.local/bin/sluice"
  [ -L "$link" ] && [ "$(readlink "$link")" = "$ROOT/bin/sluice" ]
}

@test "installed 'sluice version' runs (offline)" {
  run env SLUICE_NO_UPDATE_CHECK=1 "$TMP/.local/bin/sluice" version
  assert_success
  assert_output --partial "sluice "
}

@test "installed 'sluice help' runs" {
  run "$TMP/.local/bin/sluice" help
  assert_success
}
