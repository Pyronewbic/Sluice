#!/usr/bin/env bash
# Verify the supply-chain commands on a real built image: `sluice lock` records the multi-ecosystem
# inventory (apk+npm+pip+go), `--check`/`--diff` report drift (classified, with --json), and `--sbom`
# emits a deterministic CycloneDX 1.6 SBOM (purls + apk integrity hashes). Heavy (builds an image with
# python + go) - manual, not the PR gate.
#
#   ./test/verify-lock.sh
set -u

. "$(dirname "$0")/lib.sh"

work="$(mktemp -d)/lock"; mkdir -p "$work"
cat > "$work/sluice.config.sh" <<'CFG'
SLUICE_EXTRA_PKGS="ripgrep python-3.12 py3.12-pip go"
SLUICE_EXTRA_NPM="cowsay lodash@4.17.4"
SLUICE_SETUP_ROOT_CMDS="pip3 install --break-system-packages --quiet requests && go install rsc.io/2fa@latest"
SLUICE_RUN_CMD="bash"
CFG
container="sluice-lock"

echo "== sluice supply-chain (lock / --check / --sbom) =="
if ! ( cd "$work" && "$SLUICE" build ) >/tmp/verify-lock-build.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-lock-build.log; rm -rf "$(dirname "$work")"
  finish; exit 1
fi
ok "build"

# 1. lock records the apk + npm packages (lock lines are "apk  <name> ...", two spaces).
( cd "$work" && "$SLUICE" lock ) >/dev/null 2>&1
if grep -qE '^apk +ripgrep ' "$work/sluice.lock" && grep -qE '^npm +cowsay ' "$work/sluice.lock"; then
  ok "lock recorded ripgrep (apk) + cowsay (npm)"
else bad "lock inventory missing ripgrep/cowsay"; fi

# 2. --check is in sync right after lock (exit 0).
( cd "$work" && "$SLUICE" lock --check ) >/dev/null 2>&1 && ok "--check in sync (exit 0)" \
  || bad "--check should be in sync after lock"

# 2b. multi-ecosystem: the build-time pip + go installs are captured in the inventory.
grep -qE '^pip +requests ' "$work/sluice.lock" && ok "lock recorded requests (pip)" \
  || bad "lock inventory missing pip requests"
grep -qE '^go +rsc\.io/2fa ' "$work/sluice.lock" && ok "lock recorded rsc.io/2fa (go)" \
  || bad "lock inventory missing go rsc.io/2fa"

# 2c. --diff is read-only (exit 0) when in sync.
( cd "$work" && "$SLUICE" lock --diff ) >/dev/null 2>&1 && ok "--diff in sync (exit 0)" \
  || bad "--diff should exit 0 in sync"

# 2d. --check --json reports in_sync=true when clean.
cj="$( cd "$work" && "$SLUICE" lock --check --json 2>/dev/null )"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$cj" | jq -e '.in_sync==true' >/dev/null 2>&1 && ok "--check --json in_sync=true (clean)" \
    || bad "--check --json should be in_sync=true clean: $cj"
else
  printf '%s' "$cj" | grep -q '"in_sync":true' && ok "--check --json in_sync=true (grep)" || bad "json in_sync"
fi

# 2e. SBOM hardening: CycloneDX 1.6 + sluice tool metadata + pip purl + apk arch qualifier + SHA-1 hash.
sb="$( cd "$work" && "$SLUICE" lock --sbom 2>/dev/null )"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$sb" | jq -e '.specVersion=="1.6" and (.metadata.tools.components[0].name=="sluice")' >/dev/null 2>&1 \
    && ok "--sbom is CycloneDX 1.6 with sluice tool metadata" || bad "--sbom missing 1.6 / tools metadata"
  printf '%s' "$sb" | jq -e 'any(.components[]; (.hashes//[])[0].alg=="SHA-1")' >/dev/null 2>&1 \
    && ok "--sbom apk components carry SHA-1 hashes" || bad "--sbom missing apk SHA-1 hashes"
fi
printf '%s' "$sb" | grep -q 'pkg:pypi/requests@' && ok "--sbom has the requests pypi purl" \
  || bad "--sbom missing requests pypi purl"
printf '%s' "$sb" | grep -q 'pkg:golang/rsc.io/2fa@' && ok "--sbom has the rsc.io/2fa golang purl" \
  || bad "--sbom missing rsc.io/2fa golang purl"
printf '%s' "$sb" | grep -q 'pkg:apk/wolfi/ripgrep@.*arch=' && ok "--sbom apk purl carries arch qualifier" \
  || bad "--sbom apk purl missing arch qualifier"

# 3. drift: add a package, rebuild, --check must fail (exit 1) and name the drift.
printf 'SLUICE_EXTRA_PKGS="ripgrep python-3.12 py3.12-pip go tree"\n' >> "$work/sluice.config.sh"  # last wins
( cd "$work" && "$SLUICE" build ) >/dev/null 2>&1
out="$( cd "$work" && "$SLUICE" lock --check 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'tree'; then
  ok "--check fails on drift (exit $rc, names 'tree')"
else bad "--check should fail on drift (rc=$rc): $out"; fi
# 3b. --check --json reports in_sync=false and names the drifted package.
dj="$( cd "$work" && "$SLUICE" lock --check --json 2>/dev/null )"
if printf '%s' "$dj" | grep -q '"in_sync":false' && printf '%s' "$dj" | grep -q 'tree'; then
  ok "--check --json in_sync=false names 'tree' on drift"
else bad "--check --json should report drift: $dj"; fi
( cd "$work" && "$SLUICE" lock ) >/dev/null 2>&1   # relock clears it
( cd "$work" && "$SLUICE" lock --check ) >/dev/null 2>&1 && ok "--check in sync after relock" \
  || bad "--check should be in sync after relock"

# 4. --sbom: valid, deterministic CycloneDX with the apk + npm purls.
s1="$( cd "$work" && "$SLUICE" lock --sbom 2>/dev/null )"
s2="$( cd "$work" && "$SLUICE" lock --sbom 2>/dev/null )"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$s1" | jq -e '.bomFormat=="CycloneDX" and (.components|length>0)' >/dev/null 2>&1 \
    && ok "--sbom is valid CycloneDX JSON" || bad "--sbom not valid CycloneDX"
else
  printf '%s' "$s1" | grep -q '"bomFormat": "CycloneDX"' && ok "--sbom is CycloneDX (grep; jq absent)" \
    || bad "--sbom not CycloneDX"
fi
printf '%s' "$s1" | grep -q 'pkg:apk/wolfi/ripgrep@' && ok "--sbom has the ripgrep apk purl" \
  || bad "--sbom missing ripgrep apk purl"
printf '%s' "$s1" | grep -q 'pkg:npm/cowsay@' && ok "--sbom has the cowsay npm purl" \
  || bad "--sbom missing cowsay npm purl"
[ "$s1" = "$s2" ] && ok "--sbom is deterministic (two runs identical)" || bad "--sbom not deterministic"

# 5. lock --scan: vuln-scan the SBOM via a host scanner. Gated on a scanner being present (so it's a
# skip without one; the nightly lock job installs grype). The lodash@4.17.4 pin above carries CVEs.
if command -v grype >/dev/null 2>&1 || command -v trivy >/dev/null 2>&1; then
  sj="$( cd "$work" && "$SLUICE" lock --scan --json 2>/dev/null )"
  printf '%s' "$sj" | python3 -m json.tool >/dev/null 2>&1 \
    && ok "lock --scan --json is valid JSON" || bad "lock --scan --json invalid"
  printf '%s' "$sj" | grep -qi 'lodash' \
    && ok "lock --scan flagged the known-CVE package (lodash) from the SBOM" \
    || bad "lock --scan did not flag the planted CVE (scanner DB stale?)"
  ( cd "$work" && "$SLUICE" lock --scan --fail-on high ) >/dev/null 2>&1 \
    && bad "lock --scan --fail-on high did NOT gate on the lodash CVEs" \
    || ok "lock --scan --fail-on high gates (non-zero) on the planted CVEs"
else
  ok "lock --scan: no host scanner - soft-skip path (install grype to exercise the scan)"
fi

teardown_box "$container" "$work"; rm -rf "$(dirname "$work")" 2>/dev/null || true
finish
