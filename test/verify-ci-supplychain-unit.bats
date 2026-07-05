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
