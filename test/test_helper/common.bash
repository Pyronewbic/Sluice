#!/usr/bin/env bash
# Shared bats helper for the sluice suites.  In a .bats file:  load test_helper/common
# Provides ROOT / SLUICE / ENG, bats-assert/support/file, and the box helpers ported from the old
# test/lib.sh (host_own, teardown_box, egress assertions). bats gives each @test process isolation +
# a real failure on a failed assert - no more silent ok/bad counter or false-passes.

ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
export SLUICE_NO_BANNER=1 SLUICE_NO_UPDATE_CHECK=1

load "${BATS_TEST_DIRNAME}/test_helper/bats-support/load"
load "${BATS_TEST_DIRNAME}/test_helper/bats-assert/load"
load "${BATS_TEST_DIRNAME}/test_helper/bats-file/load"

# host_own <container> <dir>: chown a mount back to the host uid (the entrypoint chowned it to 1000 at
# run) so a host-side rewrite under it succeeds on Linux (runner uid != 1000). Container must be up.
host_own() { "$ENG" exec --user root "$1" chown -R "$(id -u):$(id -g)" "$2" >/dev/null 2>&1 || true; }

# teardown_box <container> <workdir>: chown back, stop, drop the image. Use in teardown_file.
teardown_box() {
  host_own "$1" "$2"
  ( cd "$2" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v "$1" >/dev/null 2>&1 || true
  "$ENG" rmi -f "$1" >/dev/null 2>&1 || true
}

# chown_back_tree <image> <dir>: chown a whole tree back to the host uid via a throwaway root
# container (boxes chown their mounts to uid 1000, so on Linux the host can't rm $dir otherwise).
# Use in teardown_file before rm -rf. The image only needs to exist (any sluice image works).
chown_back_tree() {
  "$ENG" run --rm --user root -v "$2:$2" --entrypoint chown "$1" -R "$(id -u):$(id -g)" "$2" >/dev/null 2>&1 || true
}

# egress_reaches <box-dir> <url>: 0 if the box reached the host (4xx still counts), with retries.
egress_reaches() {
  local d="$1" url="$2" n=1
  until ( cd "$d" && "$SLUICE" run curl -sS --max-time 15 -o /dev/null "$url" ) >/dev/null 2>&1; do
    [ "$n" -ge 3 ] && return 1; n=$((n+1)); sleep 2
  done
}
# egress_blocked <box-dir> <url>: 0 when the firewall blocks it (curl -f fails).
egress_blocked() {
  local d="$1" url="$2"
  ! ( cd "$d" && "$SLUICE" run curl -fsS --max-time 8 -o /dev/null "$url" ) >/dev/null 2>&1
}
