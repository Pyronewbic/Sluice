#!/usr/bin/env bats
# `sluice learn` end-to-end on one real built image. setup_file runs the full workflow once (audit
# discovery pass, then enforce-mode --print/--apply) and captures each output; the @tests assert on
# the captures. Ported from verify-learn.sh. Heavy - nightly, not the PR gate.
#   - audit: an OPEN-egress pass discovers reached hosts, forwards NO credentials, leaves no container
#     behind, and never leaks audit mode into the persistent enforce-mode container.
#   - enforce: --print lists the blocked hosts; --apply writes the allowlist + rebuilds so a blocked
#     host becomes reachable.
load test_helper/common

setup_file() {
  export WORK; WORK="$(mktemp -d)"; mkdir -p "$WORK/learn"
  cat > "$WORK/learn/sluice.config.sh" <<'CFG'
SLUICE_NAME="learntest"
SLUICE_ENV="AUDIT_SENTINEL"
SLUICE_RUN_CMD='printf "%s" "${AUDIT_SENTINEL:-EMPTY}" > sentinel.txt; curl -s --max-time 8 -o /dev/null https://pypi.org; curl -s --max-time 8 -o /dev/null https://files.pythonhosted.org; curl -s --max-time 6 -o /dev/null https://1.1.1.1; true'
CFG
  ( cd "$WORK/learn" && "$SLUICE" build ) >/tmp/verify-learn-build.log 2>&1 || true
  "$ENG" image inspect sluice-learntest >/dev/null 2>&1 && echo ok > "$WORK/build.ok" || echo no > "$WORK/build.ok"

  # audit pass (ephemeral, credential-stripped; AUDIT_SENTINEL is exported ONLY to prove it is NOT forwarded)
  ( cd "$WORK/learn" && SLUICE_YES=1 AUDIT_SENTINEL=LEAKED "$SLUICE" learn --audit ) > "$WORK/audit.out" 2>/dev/null || true
  cat "$WORK/learn/sentinel.txt" > "$WORK/sentinel.out" 2>/dev/null || true
  "$ENG" ps -a --format '{{.Names}}' 2>/dev/null | grep -c -- '-audit$' > "$WORK/auditctr" 2>/dev/null || echo 0 > "$WORK/auditctr"

  # enforce intact: a normal run uses the unmodified image (squid.conf still enforce)
  ( cd "$WORK/learn" && "$SLUICE" run true ) >/dev/null 2>&1 || true
  "$ENG" exec sluice-learntest grep -q '^ssl_bump splice allowed_sni$' /etc/squid.conf 2>/dev/null && echo yes > "$WORK/enforce.intact" || echo no > "$WORK/enforce.intact"

  # enforce-mode learn: run the app so it blocks + logs the hosts, then --print
  ( cd "$WORK/learn" && "$SLUICE" ) >/dev/null 2>&1 || true
  ( cd "$WORK/learn" && "$SLUICE" learn --print ) > "$WORK/print.out" 2>/dev/null || true

  # --apply rewrites sluice.config.sh on the HOST; the run above chowned $WORK/learn to uid 1000, so
  # chown it back first (Linux runner uid != 1000) or the rewrite would EACCES.
  host_own sluice-learntest "$WORK/learn"
  ( cd "$WORK/learn" && "$SLUICE" learn --apply ) >/tmp/verify-learn-apply.log 2>&1 || true
  cp "$WORK/learn/sluice.config.sh" "$WORK/applied.config" 2>/dev/null || true
  ( cd "$WORK/learn" && "$SLUICE" run sh -lc "curl -sS -o /dev/null -w '%{http_code}' --max-time 12 https://pypi.org" ) > "$WORK/applycode" 2>/dev/null || true
}

teardown_file() {
  host_own sluice-learntest "$WORK/learn"
  ( cd "$WORK/learn" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  "$ENG" rm -f sluice-learntest-audit >/dev/null 2>&1 || true
  "$ENG" rm -f -v sluice-learntest >/dev/null 2>&1 || true
  "$ENG" rmi -f sluice-learntest >/dev/null 2>&1 || true
  rm -rf "$WORK"
}

@test "learn: image built" { [ "$(cat "$WORK/build.ok")" = ok ]; }

@test "learn/audit: proposes the reached hosts" {
  grep -q 'pypi.org' "$WORK/audit.out"
  grep -q 'files.pythonhosted.org' "$WORK/audit.out"
}
@test "learn/audit: excludes the deny-canary (example.*)" { ! grep -q 'example' "$WORK/audit.out"; }
@test "learn/audit: excludes raw IPs" { ! grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$WORK/audit.out"; }
@test "learn/audit: strips credentials (SLUICE_ENV not forwarded)" { [ "$(cat "$WORK/sentinel.out" 2>/dev/null)" != LEAKED ]; }
@test "learn/audit: leaves no container behind" { [ "$(cat "$WORK/auditctr")" -eq 0 ]; }
@test "learn/audit: did not leak audit mode into the persistent container" { [ "$(cat "$WORK/enforce.intact")" = yes ]; }

@test "learn/enforce: --print lists the blocked hosts" {
  grep -q 'pypi.org' "$WORK/print.out"
  grep -q 'files.pythonhosted.org' "$WORK/print.out"
}
@test "learn/enforce: --print excludes raw IPs" { ! grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$WORK/print.out"; }
@test "learn/enforce: --apply wrote SLUICE_ALLOW_DOMAINS into the config" {
  grep -q '^SLUICE_ALLOW_DOMAINS=' "$WORK/applied.config"
  grep -q 'pypi.org' "$WORK/applied.config"
}
@test "learn/enforce: after --apply pypi.org is reachable" {
  local code; code="$(cat "$WORK/applycode" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != 000 ]
}
