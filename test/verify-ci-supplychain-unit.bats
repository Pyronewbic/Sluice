#!/usr/bin/env bats
# CI supply-chain pins (unit; no engine). The tools CI trusts (grype for lock --scan) must be pinned
# and checksum-verified, failing closed on any tamper - never curl|sh of a moving branch. Behavioral
# tamper test + structural guards so a future edit can't quietly reintroduce the unpinned form.
load test_helper/common

@test "supplychain: install-grype refuses junk bytes (checksum fails closed, nothing installed)" {
  command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not on this host (CI has it)"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/curl" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
[ -n "$out" ] && echo junk > "$out"
exit 0
EOF
  chmod +x "$tmp/curl"
  run bash -c "cd '$tmp' && HOME='$tmp' PATH='$tmp:$PATH' bash '$ROOT/scripts/install-grype.sh'"
  assert_failure
  [ ! -e "$tmp/.local/bin/grype" ]
  rm -rf "$tmp"
}

@test "supplychain: install-grype is pinned + fail-closed (structural)" {
  run grep -c 'set -euo pipefail' "$ROOT/scripts/install-grype.sh"
  assert_success
  run bash -c "grep -E '^GRYPE_SHA256=[0-9a-f]{64}' '$ROOT/scripts/install-grype.sh'"
  assert_success
  run grep -F 'sha256sum -c' "$ROOT/scripts/install-grype.sh"
  assert_success
  run grep -E '\| *(sudo +)?sh([ \t]|$)' "$ROOT/scripts/install-grype.sh"
  assert_failure
}

@test "supplychain: nightly installs grype via the pinned script, not curl|sh of main (structural)" {
  local wf="$ROOT/.github/workflows/nightly.yml"
  run grep -F 'raw.githubusercontent.com/anchore' "$wf"
  assert_failure
  run grep -F 'sudo sh' "$wf"
  assert_failure
  run grep -F 'scripts/install-grype.sh' "$wf"
  assert_success
  run grep -F "if: matrix.suite == 'lock'" "$wf"
  assert_success
}

@test "supplychain: every scans.yml job is advisory (continue-on-error, never a required gate)" {
  local wf="$ROOT/.github/workflows/scans.yml"
  [ "$(grep -c 'runs-on:' "$wf")" = 3 ]
  [ "$(grep -c 'continue-on-error: true' "$wf")" = 3 ]
}

@test "supplychain: scans.yml stays read-only (no SARIF/security-events, no write grants)" {
  local wf="$ROOT/.github/workflows/scans.yml"
  run grep -F 'security-events' "$wf"
  assert_failure
  run grep -F ': write' "$wf"
  assert_failure
  run grep -F 'contents: read' "$wf"
  assert_success
}

@test "supplychain: every workflow action ref is SHA-pinned (fleet-wide)" {
  run bash -c "grep -h 'uses:' \"$ROOT\"/.github/workflows/*.yml | grep -Ev '@[0-9a-f]{40}'"
  assert_failure
}

@test "supplychain: make lint-ci runs the same digest-pinned actionlint image as scans.yml" {
  local mk wf
  mk="$(grep -o 'rhysd/actionlint:[^ ]*' "$ROOT/Makefile" | head -1)"
  wf="$(grep -o 'rhysd/actionlint:[^ ]*' "$ROOT/.github/workflows/scans.yml" | head -1)"
  [ -n "$mk" ] && [ "$mk" = "$wf" ]
}
