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

@test "supplychain: every checkout sets persist-credentials: false (no artipacked, fleet-wide)" {
  # zizmor's artipacked audit: a checkout persists the token in .git/config unless disabled. None of
  # the workflows do authenticated git ops, so every checkout must opt out. Guards the required lane
  # since the zizmor lane is only advisory. (Exempt a genuinely credential-needing checkout here if one
  # is ever added.)
  local co pc
  co="$(grep -rh 'actions/checkout@' "$ROOT"/.github/workflows/*.yml | wc -l | tr -d ' ')"
  pc="$(grep -rh 'persist-credentials: false' "$ROOT"/.github/workflows/*.yml | wc -l | tr -d ' ')"
  [ "$co" = "$pc" ]
}

@test "supplychain: make lint-ci runs the same digest-pinned actionlint image as scans.yml" {
  local mk wf
  mk="$(grep -o 'rhysd/actionlint:[^ ]*' "$ROOT/Makefile" | head -1)"
  wf="$(grep -o 'rhysd/actionlint:[^ ]*' "$ROOT/.github/workflows/scans.yml" | head -1)"
  [ -n "$mk" ] && [ "$mk" = "$wf" ]
}

# Global npm must be enumerated at FULL closure (--all), like apk/pip/gem - not top-level-only
# (--depth=0), or a transitive-npm CVE stays invisible to `sluice lock --scan`.
@test "supplychain: global npm is enumerated at full closure (--all), in both inventory + sbom" {
  [ "$(grep -c 'npm ls -g --all --json' "$ROOT/bin/sluice")" -ge 2 ]
  run grep -F 'npm ls -g --depth=0' "$ROOT/bin/sluice"
  assert_failure   # the top-level-only form is gone
}


# --- coverage gaps surfaced by the test-case review (changed-behavior edge/bad paths) ---
@test "supplychain: npm --all closure dedups a shared transitive dep (sort -u), keeps transitive rows" {
  command -v jq >/dev/null 2>&1 || skip "jq not on this host"
  local line; line="$(grep -F 'npm ls -g --all --json' "$ROOT/bin/sluice" | grep -F 'sort -u')"
  [ -n "$line" ]
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/npm" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"dependencies":{"pkgA":{"version":"1.0.0","dependencies":{"shared":{"version":"9.9.9"}}},"pkgB":{"version":"2.0.0","dependencies":{"shared":{"version":"9.9.9"}}}}}
JSON
EOF
  chmod +x "$tmp/npm"
  run env PATH="$tmp:$PATH" bash -c "$line"
  rm -rf "$tmp"
  assert_success
  [ "$(printf '%s\n' "$output" | grep -c 'shared')" = 1 ]
  assert_output --partial "pkgA"
  assert_output --partial "pkgB"
}

# SECURITY.md tells a user to re-derive a release and compare shas. That check must be one that
# actually holds on every platform: `git archive` is deterministic, but the gzip wrapper is NOT
# (GNU gzip on the release runner vs Apple gzip on macOS produce different DEFLATE for identical
# input), so documenting the .tar.gz sha as reproducible makes a macOS user conclude the release was
# tampered with. Verified against v0.10.0: tar layers identical, .tar.gz shas differ.
@test "supplychain: the documented release repro compares the TAR layer, not the gzip" {
  run grep -c 'gunzip -c sluice-<version>.tar.gz' "$ROOT/SECURITY.md"
  assert_output "1"
  # the retired claim - gzip -n9 regenerating "the same bytes" - must not come back
  run grep -c 'gzip -n9` regenerates the same bytes' "$ROOT/SECURITY.md"
  assert_output "0"
  # and the repro pipeline must not hash with shasum alone: Alpine and *-slim have sha256sum, no shasum
  run grep -cE '^(gunzip -c|git archive).*\| shasum' "$ROOT/SECURITY.md"
  assert_output "0"
  # the retired claim must not survive in the RELEASE WORKFLOW either - it documents the same artifact,
  # and a guard that only greps SECURITY.md leaves the contradiction in place (found by review).
  run grep -c 'byte-identical' "$ROOT/.github/workflows/release.yml"
  assert_output "0"
}

@test "supplychain: git archive is byte-stable, so the documented tar comparison is sound" {
  local a b
  a="$(git -C "$ROOT" archive --format=tar --prefix=s/ HEAD | shasum -a 256 | cut -d' ' -f1)"
  b="$(git -C "$ROOT" archive --format=tar --prefix=s/ HEAD | shasum -a 256 | cut -d' ' -f1)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# The Wolfi repo signing key is VENDORED (core/wolfi-signing.rsa.pub), never TOFU-fetched at build.
# Refresh procedure lives in the Dockerfile comment: re-fetch from packages.wolfi.dev AND the
# wolfi-base image, require byte-identity, update the file + the constant here in one commit.
WOLFI_KEY_SHA256=f0031424cf46f7db780ce63a45f0fd6aa6f85f601e6bb3b7a91fe3d4d5b7d2cc  # gitleaks:allow - sha256 of a PUBLIC signing key, not a secret

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

@test "supplychain: the vendored Wolfi signing key matches its pinned checksum" {
  [ -f "$ROOT/core/wolfi-signing.rsa.pub" ]
  local got; got="$(_sha256_file "$ROOT/core/wolfi-signing.rsa.pub")"
  [ "$got" = "$WOLFI_KEY_SHA256" ] || { echo "vendored key checksum drift: $got"; return 1; }
}

@test "supplychain: the Dockerfile COPYs the vendored key and never fetches it" {
  run grep -E '^COPY[[:space:]]+wolfi-signing\.rsa\.pub[[:space:]]+/etc/apk/keys/' "$ROOT/core/Dockerfile"
  assert_success
  run grep -E 'curl.*wolfi-signing' "$ROOT/core/Dockerfile"
  assert_failure
}

# The weekly refresh may only move :latest, behind the scan gate, on the shared concurrency group -
# and grype only via the pinned installer. Structural, in the nightly guard's style: a future edit
# can't quietly widen the refresh to version tags or bypass the gate without failing here.
@test "supplychain: publish-base refresh mode is gated, scheduled, serialized, and :latest-only" {
  local wf="$ROOT/.github/workflows/publish-base.yml"
  run grep -F 'raw.githubusercontent.com/anchore' "$wf"
  assert_failure
  run grep -F 'scripts/install-grype.sh' "$wf"
  assert_success
  run grep -F 'scripts/base-scan-gate.sh' "$wf"
  assert_success
  run grep -E 'cron:' "$wf"
  assert_success
  run grep -F 'group: publish-base' "$wf"
  assert_success
  # Exactly ONE multi-arch build (the candidate) - the published bytes must be the evaluated bytes,
  # never a second from-scratch rebuild-to-push. Promotion is a re-tag (imagetools create), which
  # rebuilds nothing: refresh moves :latest only, release moves the frozen version tag too.
  [ "$(grep -cF 'buildx build --platform linux/amd64,linux/arm64' "$wf")" = 1 ]
  run grep -F -- '-t "${IMAGE}:candidate" --push --metadata-file cand-meta.json' "$wf"
  assert_success
  run grep -F 'imagetools create -t "${IMAGE}:latest" "${IMAGE}@${DIGEST}"' "$wf"
  assert_success   # refresh: :latest only
  run grep -F 'imagetools create -t "${IMAGE}:${REF_NAME}" -t "${IMAGE}:latest" "${IMAGE}@${DIGEST}"' "$wf"
  assert_success   # release: both, ungated (the human override)
  # A workflow_dispatch from a tag ref must be refused, never silently run release mode.
  run grep -F 'manual dispatch from a tag ref' "$wf"
  assert_success
  # The gate must scan the IMAGES by digest, never the sluice SBOM: the six-ecosystem SBOM lists gh as
  # one apk package, so an sbom: scan is structurally blind to go-module CVEs vendored inside it (the
  # exact class - GHSA-hrxh-6v49-42gf in gh's grpc - that motivated the gate). Proven live: sbom: scans
  # of both sides returned zero while a docker: scan of the same published image returned six.
  run grep -F 'grype "sbom:' "$wf"
  assert_failure
  [ "$(grep -cF 'grype "docker:' "$wf")" = 2 ]
}

# The BASE cosign identity regexp appears in the launcher (x2, via bin/sluice), the publish workflow
# (x2) and two docs (supply-chain x2, SECURITY x1). All 7 must be BYTE-IDENTICAL - a drifted copy
# verifies against a different signer set - and must accept BOTH legitimate signing refs: a v tag
# (release) and refs/heads/main (scheduled refresh + workflow_dispatch sign at the branch ref).
# The policy-signing identity (SLUICE_POLICY_IDENTITY, docs/policy.md) is a separate feature and
# deliberately NOT in this sync set.
@test "supplychain: the base cosign identity regexp is identical in all 7 places and accepts main" {
  local all
  all="$( { grep -o "certificate-identity-regexp='[^']*'" "$ROOT/bin/sluice"
            grep -o "certificate-identity-regexp='[^']*'" "$ROOT/.github/workflows/publish-base.yml"
            grep -o "certificate-identity-regexp='[^']*'" "$ROOT/docs/supply-chain.md"
            grep -o "certificate-identity-regexp='[^']*'" "$ROOT/SECURITY.md"; } | grep publish-base )"
  [ "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" = 7 ] || { echo "expected 7 occurrences, got:"; printf '%s\n' "$all"; return 1; }
  [ "$(printf '%s\n' "$all" | sort -u | wc -l | tr -d ' ')" = 1 ] || { echo "regexp drift:"; printf '%s\n' "$all" | sort -u; return 1; }
  printf '%s\n' "$all" | head -1 | grep -qF 'refs/heads/main$' || { echo "regexp does not accept the main signing ref"; return 1; }
}
