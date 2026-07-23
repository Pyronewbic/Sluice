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
  # ref1/ref2 differ only in embedded image-ref and purl order: identity is the sorted SET, not bytes.
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
  run "$GATE" "$FIX/cdx-hollow.json" "$FIX/cdx-hollow.json" "$FIX/grype-clean.json" "$FIX/grype-clean.json"
  [ "$status" -eq 4 ]
}

@test "scan-gate: wrong argument count fails closed (4)" {
  run "$GATE" "$FIX/cdx-b.json"
  [ "$status" -eq 4 ]
}

# --- attack-changes round 1: fail-open severity counting + multiset purl identity ---

@test "scan-gate: a clean scan is ZERO findings, not a phantom unknown (refuses a real new Unknown)" {
  # jq's // read the clean side's empty match stream as absent and invented a phantom 'unknown',
  # cancelling the candidate's real one into a PUSH.
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-1unknown.json" "$FIX/grype-clean.json"
  [ "$status" -eq 3 ]
}

@test "scan-gate: an off-list severity string is not invisible - a worse candidate still refuses (3)" {
  # 'Moderate' matches no tier; the old filter dropped it, so a strictly-worse candidate PUSHed.
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-1moderate.json" "$FIX/grype-clean.json"
  [ "$status" -eq 3 ]
}

@test "scan-gate: duplicate purls are one SET member - a dup-only diff SKIPs (2), not a no-op PUSH" {
  run "$GATE" "$FIX/cdx-dup.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-clean.json" "$FIX/grype-clean.json"
  [ "$status" -eq 2 ]
}

@test "scan-gate: an embedded-newline purl stays one distinct member, not two SKIP-matching lines" {
  # a raw-line multiset splits the forged purl into lines equal to {bash,curl} and SKIPs; the jq-array
  # compare keeps it one distinct member.
  run "$GATE" "$FIX/cdx-newline.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-clean.json" "$FIX/grype-clean.json"
  [ "$status" -ne 2 ]
}

# --- attack-changes round 2: multi-document JSON smuggling ---

@test "scan-gate: a multi-document SBOM stream fails closed (4), not smuggled past the hollow guard" {
  # '{"components":[]}\n{"components":[]}' made purls() emit "[]\n[]" (two lines) != "[]", so the
  # zero-purl SBOM sailed past the hollow guard and PUSHed.
  run "$GATE" "$FIX/cdx-multidoc-hollow.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-clean.json" "$FIX/grype-clean.json"
  [ "$status" -eq 4 ]
}

@test "scan-gate: a multi-document grype stream fails closed (4)" {
  run "$GATE" "$FIX/cdx-b.json" "$FIX/cdx-a-ref1.json" "$FIX/grype-multidoc.json" "$FIX/grype-clean.json"
  [ "$status" -eq 4 ]
}
