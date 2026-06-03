#!/usr/bin/env bats
# Supply-chain commands on a real built image (lock / --check / --diff / --sbom / --enforce / --scan).
# setup_file runs the full sequential workflow once on an image with apk+npm+pip+go+cargo inventory
# and captures every output/exit-code; the @tests assert the captures. Ported from verify-lock.sh.
# Heavy (builds python+go+rust) - nightly, not the PR gate. jq-structural checks skip without jq;
# the --scan leg skips without grype/trivy.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/lock"
  cat > "$WORK/lock/sluice.config.sh" <<'CFG'
SLUICE_EXTRA_PKGS="ripgrep python-3.12 py3.12-pip go rust"
SLUICE_EXTRA_NPM="cowsay lodash@4.17.4"
SLUICE_SETUP_ROOT_CMDS="pip3 install --break-system-packages --quiet requests && go install rsc.io/2fa@latest && mkdir -p /root/.cargo && printf '%s' '{\"installs\":{\"ripgrep 14.1.1 (registry+https://github.com/rust-lang/crates.io-index)\":{}},\"v\":4}' > /root/.cargo/.crates2.json"
SLUICE_RUN_CMD="bash"
CFG
  local rc
  ( cd "$WORK/lock" && "$SLUICE" build ) >/tmp/verify-lock-build.log 2>&1 && echo ok > "$WORK/build.ok" || echo no > "$WORK/build.ok"

  # 1. lock records the inventory
  ( cd "$WORK/lock" && "$SLUICE" lock ) >/dev/null 2>&1 || true
  cp "$WORK/lock/sluice.lock" "$WORK/lock1.txt" 2>/dev/null || true
  # 2. --check in sync ; 2c. --diff in sync ; 2d. --check --json ; 2e. --sbom (hardening)
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --check ) >/dev/null 2>&1 || rc=$?; echo "$rc" > "$WORK/check1.rc"
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --diff ) >/dev/null 2>&1 || rc=$?; echo "$rc" > "$WORK/diff1.rc"
  ( cd "$WORK/lock" && "$SLUICE" lock --check --json ) > "$WORK/checkjson1.txt" 2>/dev/null || true
  ( cd "$WORK/lock" && "$SLUICE" lock --sbom ) > "$WORK/sbom_hard.txt" 2>/dev/null || true

  # 3. drift: add a package, rebuild, --check must fail + name it
  printf 'SLUICE_EXTRA_PKGS="ripgrep python-3.12 py3.12-pip go rust tree"\n' >> "$WORK/lock/sluice.config.sh"
  ( cd "$WORK/lock" && "$SLUICE" build ) >/dev/null 2>&1 || true
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --check ) > "$WORK/driftcheck.out" 2>&1 || rc=$?; echo "$rc" > "$WORK/driftcheck.rc"
  ( cd "$WORK/lock" && "$SLUICE" lock --check --json ) > "$WORK/driftcheckjson.txt" 2>/dev/null || true
  ( cd "$WORK/lock" && "$SLUICE" lock ) >/dev/null 2>&1 || true   # relock clears it
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --check ) >/dev/null 2>&1 || rc=$?; echo "$rc" > "$WORK/checkrelock.rc"

  # 4. --sbom determinism + purls ; 4b. __sbom <image> ; 4c. spdx + cyclonedx default
  ( cd "$WORK/lock" && "$SLUICE" lock --sbom ) > "$WORK/s1.txt" 2>/dev/null || true
  ( cd "$WORK/lock" && "$SLUICE" lock --sbom ) > "$WORK/s2.txt" 2>/dev/null || true
  "$SLUICE" __sbom sluice-lock > "$WORK/sbomimg.txt" 2>/dev/null || true
  ( cd "$WORK/lock" && "$SLUICE" lock --sbom --format spdx ) > "$WORK/spdx1.txt" 2>/dev/null || true
  ( cd "$WORK/lock" && "$SLUICE" lock --sbom --format spdx ) > "$WORK/spdx2.txt" 2>/dev/null || true
  ( cd "$WORK/lock" && "$SLUICE" lock --sbom --format cyclonedx ) > "$WORK/cyclonedx.txt" 2>/dev/null || true

  # 4d. --enforce: passes in sync, gates on drift, refuses a stale image
  ( cd "$WORK/lock" && "$SLUICE" lock ) >/dev/null 2>&1 || true
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --enforce ) >/dev/null 2>&1 || rc=$?; echo "$rc" > "$WORK/enforce_insync.rc"
  printf 'SLUICE_EXTRA_PKGS="ripgrep python-3.12 py3.12-pip go rust tree"\n' >> "$WORK/lock/sluice.config.sh"
  ( cd "$WORK/lock" && "$SLUICE" build ) >/dev/null 2>&1 || true
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --enforce ) >/dev/null 2>&1 || rc=$?; echo "$rc" > "$WORK/enforce_drift.rc"
  ( cd "$WORK/lock" && "$SLUICE" lock ) >/dev/null 2>&1 || true
  printf 'SLUICE_EXTRA_PKGS="ripgrep python-3.12 py3.12-pip go rust tree git"\n' >> "$WORK/lock/sluice.config.sh"   # confighash changes; do NOT rebuild
  rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --enforce ) > "$WORK/enforce_stale.out" 2>&1 || rc=$?; echo "$rc" > "$WORK/enforce_stale.rc"
  ( cd "$WORK/lock" && "$SLUICE" build ) >/dev/null 2>&1 || true   # restore a non-stale image + lock
  ( cd "$WORK/lock" && "$SLUICE" lock ) >/dev/null 2>&1 || true

  # 5. --scan (gated on a host scanner)
  if command -v grype >/dev/null 2>&1 || command -v trivy >/dev/null 2>&1; then
    ( cd "$WORK/lock" && "$SLUICE" lock --scan --json ) > "$WORK/scan.json" 2>/dev/null || true
    rc=0; ( cd "$WORK/lock" && "$SLUICE" lock --scan --fail-on high ) >/dev/null 2>&1 || rc=$?; echo "$rc" > "$WORK/scan_failon.rc"
    echo present > "$WORK/scanner"
  else
    echo absent > "$WORK/scanner"
  fi
}

teardown_file() {
  chown_back_tree sluice-lock "$WORK"
  ( cd "$WORK/lock" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-lock >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-lock >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "lock: image built" { [ "$(cat "$WORK/build.ok")" = ok ]; }

@test "lock: recorded ripgrep (apk) + cowsay (npm)" {
  grep -qE '^apk +ripgrep ' "$WORK/lock1.txt"
  grep -qE '^npm +cowsay ' "$WORK/lock1.txt"
}
@test "lock --check: in sync right after lock (exit 0)" { [ "$(cat "$WORK/check1.rc")" = 0 ]; }
@test "lock: multi-ecosystem inventory (pip requests, go 2fa, cargo ripgrep)" {
  grep -qE '^pip +requests ' "$WORK/lock1.txt"
  grep -qE '^go +rsc\.io/2fa ' "$WORK/lock1.txt"
  grep -qE '^cargo +ripgrep ' "$WORK/lock1.txt"
}
@test "lock --diff: read-only, exit 0 in sync" { [ "$(cat "$WORK/diff1.rc")" = 0 ]; }
@test "lock --check --json: in_sync=true when clean" { grep -q '"in_sync":true' "$WORK/checkjson1.txt"; }

@test "lock --sbom: CycloneDX 1.6 + sluice tool metadata (jq)" {
  command -v jq >/dev/null || skip "jq absent"
  jq -e '.specVersion=="1.6" and (.metadata.tools.components[0].name=="sluice")' < "$WORK/sbom_hard.txt" >/dev/null
}
@test "lock --sbom: apk components carry SHA-1 hashes (jq)" {
  command -v jq >/dev/null || skip "jq absent"
  jq -e 'any(.components[]; (.hashes//[])[0].alg=="SHA-1")' < "$WORK/sbom_hard.txt" >/dev/null
}
@test "lock --sbom: pip purl + golang purl + apk arch qualifier" {
  grep -q 'pkg:pypi/requests@' "$WORK/sbom_hard.txt"
  grep -q 'pkg:golang/rsc.io/2fa@' "$WORK/sbom_hard.txt"
  grep -q 'pkg:apk/wolfi/ripgrep@.*arch=' "$WORK/sbom_hard.txt"
}

@test "lock --check: fails on drift (non-zero, names 'tree')" {
  [ "$(cat "$WORK/driftcheck.rc")" != 0 ]
  grep -q 'tree' "$WORK/driftcheck.out"
}
@test "lock --check --json: in_sync=false names 'tree' on drift" {
  grep -q '"in_sync":false' "$WORK/driftcheckjson.txt"
  grep -q 'tree' "$WORK/driftcheckjson.txt"
}
@test "lock --check: in sync after relock (exit 0)" { [ "$(cat "$WORK/checkrelock.rc")" = 0 ]; }

@test "lock --sbom: deterministic (two runs identical)" { cmp -s "$WORK/s1.txt" "$WORK/s2.txt"; }
@test "lock --sbom: valid CycloneDX with apk/npm/cargo purls" {
  if command -v jq >/dev/null; then jq -e '.bomFormat=="CycloneDX" and (.components|length>0)' < "$WORK/s1.txt" >/dev/null
  else grep -q '"bomFormat": "CycloneDX"' "$WORK/s1.txt"; fi
  grep -q 'pkg:apk/wolfi/ripgrep@' "$WORK/s1.txt"
  grep -q 'pkg:npm/cowsay@' "$WORK/s1.txt"
  grep -q 'pkg:cargo/ripgrep@' "$WORK/s1.txt"
}
@test "lock: __sbom <image> matches lock --sbom (attestation codepath)" { cmp -s "$WORK/sbomimg.txt" "$WORK/s1.txt"; }
@test "lock --sbom --format spdx: valid SPDX 2.3, deterministic, shared purls" {
  command -v jq >/dev/null && jq -e '.spdxVersion=="SPDX-2.3" and (.packages|length>0)' < "$WORK/spdx1.txt" >/dev/null
  grep -q 'pkg:apk/wolfi/ripgrep@' "$WORK/spdx1.txt"
  grep -q 'pkg:cargo/ripgrep@' "$WORK/spdx1.txt"
  cmp -s "$WORK/spdx1.txt" "$WORK/spdx2.txt"
}
@test "lock --sbom --format cyclonedx == bare --sbom (default unchanged)" { cmp -s "$WORK/cyclonedx.txt" "$WORK/s1.txt"; }

@test "lock --enforce: passes in sync" { [ "$(cat "$WORK/enforce_insync.rc")" = 0 ]; }
@test "lock --enforce: gates (non-zero) on drift" { [ "$(cat "$WORK/enforce_drift.rc")" != 0 ]; }
@test "lock --enforce: refuses a stale image (asks rebuild)" {
  [ "$(cat "$WORK/enforce_stale.rc")" != 0 ]
  grep -qi rebuild "$WORK/enforce_stale.out"
}

@test "lock --scan --json: valid JSON" {
  [ "$(cat "$WORK/scanner")" = present ] || skip "no host scanner (install grype to exercise --scan)"
  python3 -m json.tool < "$WORK/scan.json" >/dev/null
}
@test "lock --scan: flags the planted lodash CVE" {
  [ "$(cat "$WORK/scanner")" = present ] || skip "no host scanner"
  grep -qi 'lodash' "$WORK/scan.json"
}
@test "lock --scan --fail-on high: gates (non-zero) on the planted CVEs" {
  [ "$(cat "$WORK/scanner")" = present ] || skip "no host scanner"
  [ "$(cat "$WORK/scan_failon.rc")" != 0 ]
}
