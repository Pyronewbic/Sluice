#!/usr/bin/env bash
# Verify the supply-chain commands on a real built image: `sluice lock` records the inventory,
# `sluice lock --check` is in-sync then fails (exit 1) on drift, and `sluice lock --sbom` emits a
# deterministic CycloneDX SBOM with apk + npm purls. Heavy (builds an image) - manual, not the PR gate.
#
#   ./test/verify-lock.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

work="$(mktemp -d)/lock"; mkdir -p "$work"
cat > "$work/sluice.config.sh" <<'CFG'
SLUICE_EXTRA_PKGS="ripgrep"
SLUICE_EXTRA_NPM="cowsay"
SLUICE_RUN_CMD="bash"
CFG
container="sluice-lock"
export SLUICE_NO_BANNER=1

echo "== sluice supply-chain (lock / --check / --sbom) =="
if ! ( cd "$work" && "$SLUICE" build ) >/tmp/verify-lock-build.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-lock-build.log; rm -rf "$(dirname "$work")"
  echo "== $PASS passed, $FAIL failed =="; exit 1
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

# 3. drift: add a package, rebuild, --check must fail (exit 1) and name the drift.
printf 'SLUICE_EXTRA_PKGS="ripgrep tree"\n' >> "$work/sluice.config.sh"   # last assignment wins
( cd "$work" && "$SLUICE" build ) >/dev/null 2>&1
out="$( cd "$work" && "$SLUICE" lock --check 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'tree'; then
  ok "--check fails on drift (exit $rc, names 'tree')"
else bad "--check should fail on drift (rc=$rc): $out"; fi
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

# Teardown: chown the mount back so the host can clean up (see verify-agents.sh).
"$ENG" exec --user root "$container" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
"$ENG" rmi -f "$container" >/dev/null 2>&1 || true
rm -rf "$(dirname "$work")" 2>/dev/null || true

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
