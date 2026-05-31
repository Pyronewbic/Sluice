#!/usr/bin/env bash
# Verify `sluice learn` on a real built image: --print lists the blocked hosts (the deny-canary,
# raw IPs, and base hosts excluded), and --apply writes the allowlist + rebuilds so the host becomes
# reachable. Heavy (builds an image) - manual, not the PR gate.
#
#   ./test/verify-learn.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

work="$(mktemp -d)/learn"; mkdir -p "$work"
cat > "$work/sluice.config.sh" <<'CFG'
# Reaches two non-allowlisted hosts (blocked + logged) and a raw IP (must be excluded from proposals).
SLUICE_RUN_CMD='curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; curl -s --max-time 6 -o /dev/null https://1.1.1.1; true'
CFG
container="sluice-learn"
export SLUICE_NO_BANNER=1

echo "== sluice learn (--print / --apply) =="
if ! ( cd "$work" && "$SLUICE" build ) >/tmp/verify-learn-build.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-learn-build.log; rm -rf "$(dirname "$work")"
  echo "== $PASS passed, $FAIL failed =="; exit 1
fi
ok "build"

# Run the app so it hits the blocked hosts (squid logs their SNI); the container stays up after.
( cd "$work" && "$SLUICE" ) >/dev/null 2>&1 || true

# 1. --print lists both real hosts, and excludes the canary + raw IPs.
out="$( cd "$work" && "$SLUICE" learn --print 2>/dev/null )"
if printf '%s' "$out" | grep -q 'pypi.org' && printf '%s' "$out" | grep -q 'files.pythonhosted.org'; then
  ok "--print lists the blocked hosts: $out"
else bad "--print missing a host (got: ${out:-<empty>})"; fi
printf '%s' "$out" | grep -q 'example' \
  && bad "--print leaked the deny-canary (example.*)" || ok "--print excludes the deny-canary"
printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  && bad "--print leaked a raw IP" || ok "--print excludes raw IPs"

# 2. --apply writes SLUICE_ALLOW_DOMAINS into the config and rebuilds.
( cd "$work" && "$SLUICE" learn --apply ) >/tmp/verify-learn-apply.log 2>&1
if grep -q '^SLUICE_ALLOW_DOMAINS=' "$work/sluice.config.sh" && grep -q 'pypi.org' "$work/sluice.config.sh"; then
  ok "--apply wrote SLUICE_ALLOW_DOMAINS into the config"
else bad "--apply did not write the config"; tail -5 /tmp/verify-learn-apply.log; fi

# 3. After --apply (rebuilt with the new allowlist), the host is reachable.
code="$( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 https://pypi.org" 2>/dev/null )"
{ [ -n "$code" ] && [ "$code" != 000 ]; } && ok "after --apply pypi.org reachable (HTTP $code)" \
  || bad "after --apply pypi.org still blocked (got '${code:-<empty>}')"

# Teardown: chown the mount back so the host can clean up (see verify-lock.sh).
"$ENG" exec --user root "$container" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
"$ENG" rmi -f "$container" >/dev/null 2>&1 || true
rm -rf "$(dirname "$work")" 2>/dev/null || true

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
