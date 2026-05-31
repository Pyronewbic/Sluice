#!/usr/bin/env bash
# Smoke-test the sluice image: base tooling present + the session is non-root.
# Run by `sluice smoke` (as the node user, in a throwaway container). The firewall
# allow/deny invariants are verified separately by init-firewall.sh at real boot.
# Exits non-zero if any check fails.
set -u

fail=0
check() {  # check <label> <cmd...>
  local label="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then
    printf '  ✅ %-12s %s\n' "$label" "$(printf '%s' "$out" | head -1)"
  else
    printf '  ❌ %-12s FAILED (%s)\n' "$label" "$*"
    fail=1
  fi
}

echo "[smoke] base tooling:"
check node     node --version
check npm      npm --version
check git      git --version
check gh       gh --version
check curl     curl --version
check jq       jq --version
check iptables iptables --version
check squid    sh -c 'command -v squid'   # presence only: squid runs as root at boot
check dig      dig -v

echo "[smoke] session user:"
uid="$(id -u)"
if [ "$uid" = "1000" ]; then
  printf '  ✅ %-12s uid=%s (node, non-root)\n' "non-root" "$uid"
else
  printf '  ❌ %-12s uid=%s (expected 1000/node)\n' "non-root" "$uid"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "[smoke] PASS"
else
  echo "[smoke] FAIL - see ❌ above" >&2
  exit 1
fi
