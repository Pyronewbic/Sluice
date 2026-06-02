#!/usr/bin/env bash
# Verify `sluice learn` end-to-end on one real built image - both modes, formerly two suites:
#   - enforce-mode: --print lists the blocked hosts (deny-canary / raw IPs / base excluded),
#     --apply writes the allowlist + rebuilds so the host becomes reachable.
#   - --audit: a one-shot OPEN-egress pass discovers reached hosts, forwards NO credentials, leaves no
#     audit container behind, and never leaks audit mode into the persistent enforce-mode container.
# Heavy (builds an image) - nightly, not the PR gate.
#   ./test/verify-learn.sh
set -u
. "$(dirname "$0")/lib.sh"

work="$(mktemp -d)/learn"; mkdir -p "$work"
# Reaches two non-allowlisted hosts (blocked+logged in enforce, reached in audit) + a raw IP (excluded
# from proposals), and writes a sentinel from a forwarded-in-normal-mode env var (must be EMPTY in audit).
cat > "$work/sluice.config.sh" <<'CFG'
SLUICE_NAME="learntest"
SLUICE_ENV="AUDIT_SENTINEL"
SLUICE_RUN_CMD='printf "%s" "${AUDIT_SENTINEL:-EMPTY}" > sentinel.txt; curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; curl -s --max-time 6 -o /dev/null https://1.1.1.1; true'
CFG
container="sluice-learntest"

echo "== sluice learn (--audit discovery, then enforce --print/--apply) =="
if ! ( cd "$work" && "$SLUICE" build ) >/tmp/verify-learn-build.log 2>&1; then
  bad "build"; tail -20 /tmp/verify-learn-build.log; rm -rf "$(dirname "$work")"
  finish; exit 1
fi
ok "build"

# --- audit pass first (ephemeral, credential-stripped; does NOT mutate the persistent allowlist) -----
# SLUICE_YES=1 confirms opening egress; AUDIT_SENTINEL is exported ONLY to prove it is NOT forwarded.
out="$( cd "$work" && SLUICE_YES=1 AUDIT_SENTINEL=LEAKED "$SLUICE" learn --audit 2>/dev/null )"
if printf '%s' "$out" | grep -q 'pypi.org' && printf '%s' "$out" | grep -q 'files.pythonhosted.org'; then
  ok "audit proposes the reached hosts"
else bad "audit proposal missing a reached host (got: ${out:-<empty>})"; fi
printf '%s' "$out" | grep -q 'example' \
  && bad "audit leaked the deny-canary (example.*)" || ok "audit excludes the deny-canary"
printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  && bad "audit leaked a raw IP" || ok "audit excludes raw IPs"
sent="$(cat "$work/sentinel.txt" 2>/dev/null || true)"
[ "$sent" != LEAKED ] && ok "audit strips credentials (SLUICE_ENV not forwarded; sentinel='${sent:-<empty>}')" \
  || bad "credential leak - SLUICE_ENV was forwarded into the audit run"
"$ENG" ps -a --format '{{.Names}}' 2>/dev/null | grep -q -- '-audit$' \
  && bad "an audit container was left behind" || ok "audit leaves no container behind"

# Enforce intact: a normal run uses the unmodified image (squid.conf still enforce, host still blocked).
( cd "$work" && "$SLUICE" run true ) >/dev/null 2>&1 || true
"$ENG" exec "$container" grep -q '^ssl_bump splice allowed_sni$' /etc/squid.conf 2>/dev/null \
  && ok "persistent container squid.conf is enforce (audit didn't leak)" \
  || bad "persistent container is in AUDIT mode - audit leaked"

# --- enforce-mode learn: run the app so it blocks + logs the hosts, then --print / --apply -----------
( cd "$work" && "$SLUICE" ) >/dev/null 2>&1 || true
out="$( cd "$work" && "$SLUICE" learn --print 2>/dev/null )"
if printf '%s' "$out" | grep -q 'pypi.org' && printf '%s' "$out" | grep -q 'files.pythonhosted.org'; then
  ok "--print lists the blocked hosts: $out"
else bad "--print missing a host (got: ${out:-<empty>})"; fi
printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  && bad "--print leaked a raw IP" || ok "--print excludes raw IPs"

# --apply rewrites sluice.config.sh on the HOST; the run above chowned $work to uid 1000, so chown it
# back first (Linux runner uid != 1000) or the rewrite would hit Permission denied.
host_own "$container" "$work"
( cd "$work" && "$SLUICE" learn --apply ) >/tmp/verify-learn-apply.log 2>&1
if grep -q '^SLUICE_ALLOW_DOMAINS=' "$work/sluice.config.sh" && grep -q 'pypi.org' "$work/sluice.config.sh"; then
  ok "--apply wrote SLUICE_ALLOW_DOMAINS into the config"
else bad "--apply did not write the config"; tail -5 /tmp/verify-learn-apply.log; fi
code="$( cd "$work" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 https://pypi.org" 2>/dev/null )"
{ [ -n "$code" ] && [ "$code" != 000 ]; } && ok "after --apply pypi.org reachable (HTTP $code)" \
  || bad "after --apply pypi.org still blocked (got '${code:-<empty>}')"

teardown_box "$container" "$work"
"$ENG" rm -f "$container-audit" >/dev/null 2>&1 || true   # belt-and-suspenders (EXIT trap already tore it down)
rm -rf "$(dirname "$work")" 2>/dev/null || true
finish
