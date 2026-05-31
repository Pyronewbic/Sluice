#!/usr/bin/env bash
# Verify `sluice learn --audit` on a real built image: a one-shot OPEN-egress pass discovers every
# host the app reached (canary/raw-IP/base excluded), forwards NO credentials, leaves no audit
# container behind, and never leaks audit mode into the persistent enforce-mode container.
# Heavy (builds an image) - manual, not the PR gate.
#
#   ./test/verify-audit.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

work="$(mktemp -d)/audittest"; mkdir -p "$work"
cat > "$work/sluice.config.sh" <<'CFG'
# Audit run reaches two non-allowlisted hosts (logged as reached) + a raw IP (excluded from the
# proposal), and writes a sentinel from a forwarded-in-normal-mode env var (must be EMPTY in audit).
SLUICE_ENV="AUDIT_SENTINEL"
SLUICE_RUN_CMD='printf "%s" "${AUDIT_SENTINEL:-EMPTY}" > sentinel.txt; curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; curl -s --max-time 6 -o /dev/null https://1.1.1.1; true'
CFG
container="sluice-audittest"
export SLUICE_NO_BANNER=1

echo "== sluice learn --audit =="
if ! ( cd "$work" && "$SLUICE" build ) >/tmp/verify-audit-build.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-audit-build.log; rm -rf "$(dirname "$work")"
  echo "== $PASS passed, $FAIL failed =="; exit 1
fi
ok "build"

# Run the audit pass non-interactively (SLUICE_YES=1 confirms opening egress). AUDIT_SENTINEL is
# exported here ONLY to prove it is NOT forwarded into the credential-stripped audit container.
out="$( cd "$work" && SLUICE_YES=1 AUDIT_SENTINEL=LEAKED "$SLUICE" learn --audit 2>/dev/null )"

# 1. The proposal lists both reached hosts, and excludes the canary + raw IPs.
if printf '%s' "$out" | grep -q 'pypi.org' && printf '%s' "$out" | grep -q 'files.pythonhosted.org'; then
  ok "audit proposes the reached hosts"
else bad "audit proposal missing a reached host (got: ${out:-<empty>})"; fi
printf '%s' "$out" | grep -q 'example' \
  && bad "audit proposal leaked the deny-canary (example.*)" || ok "audit excludes the deny-canary"
printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  && bad "audit proposal leaked a raw IP" || ok "audit excludes raw IPs"

# 2. Credentials are stripped: the forwarded-in-normal-mode env var is absent in the audit run.
sent="$(cat "$work/sentinel.txt" 2>/dev/null || true)"
[ "$sent" != LEAKED ] \
  && ok "credentials stripped (SLUICE_ENV not forwarded; sentinel='${sent:-<empty>}')" \
  || bad "credential leak - SLUICE_ENV was forwarded into the audit run"

# 3. No residue: the ephemeral audit container is torn down (EXIT trap), even non-interactively.
"$ENG" ps -a --format '{{.Names}}' 2>/dev/null | grep -q -- '-audit$' \
  && bad "an audit container was left behind" || ok "no audit container remains"

# 4. Enforce mode intact: a normal run uses the unmodified image, so squid.conf is still enforce
#    and a non-allowlisted host stays blocked (audit didn't write the config or leak into the image).
( cd "$work" && "$SLUICE" run true ) >/dev/null 2>&1 || true   # ensure the persistent container is up
"$ENG" exec "$container" grep -q '^ssl_bump splice allowed_sni$' /etc/squid.conf 2>/dev/null \
  && ok "persistent container squid.conf is enforce (splice allowed_sni)" \
  || bad "persistent container is in AUDIT mode - audit leaked"
code="$( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://pypi.org" 2>/dev/null )"
{ [ -z "$code" ] || [ "$code" = 000 ]; } \
  && ok "enforce still blocks pypi.org after audit (got '${code:-<empty>}')" \
  || bad "enforce leaked - pypi.org reachable after audit (HTTP $code)"

# Teardown: chown the mount back so the host can clean up (see verify-lock.sh).
"$ENG" exec --user root "$container" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
"$ENG" rm -f "$container-audit" >/dev/null 2>&1 || true
( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
"$ENG" rmi -f "$container" >/dev/null 2>&1 || true
rm -rf "$(dirname "$work")" 2>/dev/null || true

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
