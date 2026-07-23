#!/usr/bin/env bash
# base-scan-gate.sh <cand.cdx.json> <cur.cdx.json> <cand.grype.json> <cur.grype.json>
# Decides whether a rebuilt base may replace the published :latest. Exit contract (mirrors the
# `sluice lock --scan` style - a tripped gate and a broken checker are DIFFERENT codes):
#   0  PUSH    candidate inventory differs and is no worse at every severity tier
#   2  SKIP    candidate inventory is purl-identical to the published one (no churn push)
#   3  REFUSE  candidate is worse at some tier (more findings at-or-above it)
#   4  FAILED  missing tool/file, unparsable JSON, wrong shape, hollow SBOM - the gate did NOT evaluate
# Inventory identity is the sorted purl SET, never raw bytes: the deterministic SBOM embeds the image
# ref in metadata.component.name, so byte-compare across sluice-base:smoke vs ghcr.io/...:latest can
# never match. Severity rule is cumulative dominance in grype's order (critical > high > medium >
# low > negligible > unknown): a same-tier CVE swap or a severity downgrade passes (rolling-repo
# reality), any net worsening at any tier refuses.
set -euo pipefail

fail4() { echo "[scan-gate] FAILED: $*" >&2; exit 4; }

[ "$#" -eq 4 ] || fail4 "usage: base-scan-gate.sh <cand.cdx.json> <cur.cdx.json> <cand.grype.json> <cur.grype.json>"
command -v jq >/dev/null 2>&1 || fail4 "jq not found - cannot evaluate"

CAND_SBOM=$1 CUR_SBOM=$2 CAND_SCAN=$3 CUR_SCAN=$4
for f in "$CAND_SBOM" "$CUR_SBOM" "$CAND_SCAN" "$CUR_SCAN"; do
  [ -f "$f" ] || fail4 "missing input: $f"
done
for f in "$CAND_SBOM" "$CUR_SBOM"; do
  jq -e '.components | type == "array"' "$f" >/dev/null 2>&1 || fail4 "not a CycloneDX components document: $f"
done
for f in "$CAND_SCAN" "$CUR_SCAN"; do
  jq -e '.matches | type == "array"' "$f" >/dev/null 2>&1 || fail4 "not a grype matches document: $f"
done

# The purl SET as a single-line JSON array (jq `unique` dedups; embedded newlines stay escaped as the
# two chars backslash-n, so a forged multi-line purl can never equal two separate purls - a raw-line
# `sort -u` would be blind to both).
purls() { jq -c '[.components[].purl // empty] | unique' "$1"; }
cand_purls="$(purls "$CAND_SBOM")" || fail4 "purl extraction failed: $CAND_SBOM"
cur_purls="$(purls "$CUR_SBOM")"   || fail4 "purl extraction failed: $CUR_SBOM"
# a hollow SBOM must fail, not SKIP-by-emptiness: two masked inventory reads compare equal forever.
[ "$cand_purls" != "[]" ] || fail4 "hollow SBOM (zero purls): $CAND_SBOM"
[ "$cur_purls" != "[]" ]  || fail4 "hollow SBOM (zero purls): $CUR_SBOM"
if [ "$cand_purls" = "$cur_purls" ]; then
  echo "[scan-gate] SKIP: candidate inventory is purl-identical to the published base" >&2
  exit 2
fi

# findings at exactly this severity. Two fail-open traps closed: (1) bind the "unknown" fallback
# PER ELEMENT - a top-level `.severity // "unknown"` on an EMPTY match stream yields one phantom
# "unknown" (jq's // treats empty as absent), miscounting a clean scan as one finding; (2) fold any
# present-but-unrecognized string ("", "Moderate", a future grype vocab) into "unknown", so an
# off-list severity can never be invisible to every tier and let a worse candidate through.
count_sev() {
  local n
  n="$(jq -r --arg s "$2" \
    '[ .matches[]
       | ( .vulnerability.severity // "unknown" | ascii_downcase )
       | ( if IN("critical","high","medium","low","negligible","unknown") then . else "unknown" end )
       | select(. == $s) ] | length' \
    "$1" 2>/dev/null)" || return 1
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}

cum_cand=0 cum_cur=0
for sev in critical high medium low negligible unknown; do
  c="$(count_sev "$CAND_SCAN" "$sev")" || fail4 "severity count failed ($sev): $CAND_SCAN"
  p="$(count_sev "$CUR_SCAN" "$sev")"  || fail4 "severity count failed ($sev): $CUR_SCAN"
  cum_cand=$((cum_cand + c)); cum_cur=$((cum_cur + p))
  if [ "$cum_cand" -gt "$cum_cur" ]; then
    echo "[scan-gate] REFUSE: candidate has $cum_cand findings at or above '$sev', published has $cum_cur" >&2
    exit 3
  fi
done
echo "[scan-gate] PUSH: inventory changed and the candidate is no worse at every severity tier" >&2
exit 0
