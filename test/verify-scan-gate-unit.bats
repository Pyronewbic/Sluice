#!/usr/bin/env bats
# scripts/base-scan-gate.sh decides whether a rebuilt base may replace the published :latest.
# Exit contract (mirrors the lock --scan style): 0 PUSH / 2 SKIP (purl-identical inventory) /
# 3 REFUSE (worse at some severity tier) / 4 the gate could not evaluate (fail closed - a broken
# scanner or input must never read as PUSH). Driven entirely by canned fixtures; no engine, no network.
load test_helper/common

setup() {
  FIX="$BATS_TEST_DIRNAME/fixtures/scan-gate"
  GATE="$ROOT/scripts/base-scan-gate.sh"
  command -v jq >/dev/null 2>&1 || skip "jq required for the gate suite"
}

@test "scan-gate: purl-identical inventories SKIP (2) even when the scans differ" {
  # ref1/ref2 differ in metadata.component.name (the image ref the SBOM embeds) and purl ORDER -
  # only the sorted purl SET may decide identity, or weekly refreshes push no-op images forever.
  run "$GATE" "$FIX/cdx-a-ref1.json" "$FIX/cdx-a-ref2.json" "$FIX/grype-1high.json" "$FIX/grype-clean.json"
  [ "$status" -eq 2 ]
}

@test "scan-gate: a NEW High refuses (3)" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-1high.json" "$FIX/grype-clean.json"
  [ "$status" -eq 3 ]
}

@test "scan-gate: a FIXED High pushes (0)" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-clean.json" "$FIX/grype-1high.json"
  [ "$status" -eq 0 ]
}

@test "scan-gate: a same-tier CVE swap pushes (0) - rolling-repo reality" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-1high-other.json" "$FIX/grype-1high.json"
  [ "$status" -eq 0 ]
}

@test "scan-gate: a High traded for a Low pushes (0) - cumulative dominance permits downgrades" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-1low.json" "$FIX/grype-1high.json"
  [ "$status" -eq 0 ]
}

@test "scan-gate: a pure new Low refuses (3) - any net worsening at any tier" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-1low.json" "$FIX/grype-clean.json"
  [ "$status" -eq 3 ]
}

@test "scan-gate: malformed scan JSON fails closed (4, not PUSH)" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-garbage.json" "$FIX/grype-clean.json"
  [ "$status" -eq 4 ]
}

@test "scan-gate: a missing input file fails closed (4)" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/does-not-exist.json" "$FIX/grype-clean.json"
  [ "$status" -eq 4 ]
}

@test "scan-gate: a broken jq fails closed (4) - the gate never guesses without its parser" {
  local shim; shim="$(mktemp -d)"
  printf '#!/bin/sh\nexit 127\n' > "$shim/jq"; chmod +x "$shim/jq"
  run env PATH="$shim:$PATH" "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-clean.json" "$FIX/grype-clean.json"
  rm -rf "$shim"
  [ "$status" -eq 4 ]
}

@test "scan-gate: a hollow SBOM (zero purls) fails closed (4), never SKIP-by-emptiness" {
  # two hollow SBOMs compare equal as empty sets; without this guard a masked inventory read would
  # SKIP forever and the published base would silently fossilize again.
  run "$GATE" "$FIX/cdx-hollow.json" "$FIX/cdx-hollow.json" "$FIX/grype-clean.json" "$FIX/grype-clean.json"
  [ "$status" -eq 4 ]
}

@test "scan-gate: wrong argument count fails closed (4)" {
  run "$GATE" "$FIX/cdx-b.json"
  [ "$status" -eq 4 ]
}
