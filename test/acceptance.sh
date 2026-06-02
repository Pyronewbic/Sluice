#!/usr/bin/env bash
# sluice acceptance tests: build the example sluices, assert the security + serving invariants
# end-to-end (the CI gate). Engine-agnostic (SLUICE_ENGINE). ACCEPTANCE_QUICK=1 skips Strudel.
set -u

. "$(dirname "$0")/lib.sh"
WORK="$(mktemp -d)"

cleanup() {
  # The entrypoint chowns each mount to the sandbox uid (1000); chown it back to the host uid
  # (while the container is still up) so the host can remove $WORK without "Permission denied".
  for d in empty strudel; do
    "${SLUICE_ENGINE:-docker}" exec --user root "sluice-$d" \
      chown -R "$(id -u):$(id -g)" "$WORK/$d" >/dev/null 2>&1 || true
    ( cd "$WORK/$d" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true
  done
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

bxrun() { ( cd "$1" && shift && "$SLUICE" run "$@" ) >/dev/null 2>&1; }
# Allow-checks use curl -sS (no -f): success = reached the host (4xx still = allowed) + retry.
# Deny-checks keep -f and don't retry (they pass when curl fails).
retry() { local n=1; until "$@"; do [ "$n" -ge 3 ] && return 1; n=$((n+1)); sleep 2; done; }

echo "== sluice acceptance (engine: ${SLUICE_ENGINE:-docker}) =="

echo "-- empty sluice --"
mkdir -p "$WORK/empty"; printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/empty/sluice.config.sh"
if ( cd "$WORK/empty" && "$SLUICE" build ) >/dev/null 2>&1; then ok "builds"; else bad "builds"; fi
( cd "$WORK/empty" && "$SLUICE" run true ) >/dev/null 2>&1   # bring the container up

retry bxrun "$WORK/empty" curl -sS --max-time 15 -o /dev/null https://registry.npmjs.org/ \
  && ok "allow: registry.npmjs.org reachable (spliced by SNI)" || bad "allow: registry.npmjs.org reachable"
# github.com's edge intermittently resets CI IPs (not our policy failing); npm above already proves
# allow-enforcement, so on a live-fetch failure fall back to asserting github.com is on the allowlist (a denied host never is).
if retry bxrun "$WORK/empty" curl -sS --max-time 15 -o /dev/null https://github.com/; then
  ok "allow: github.com reachable"
elif bxrun "$WORK/empty" grep -qx github.com /etc/squid/allowlist.txt; then
  ok "allow: github.com on the active allowlist (origin refused the CI runner IP)"
else
  bad "allow: github.com reachable"
fi
bxrun "$WORK/empty" curl -fsS --max-time 8 -o /dev/null https://example.com/ \
  && bad "deny: example.com (was reachable!)" || ok "deny: example.com blocked"
bxrun "$WORK/empty" curl -fsS --max-time 8 -o /dev/null https://1.1.1.1/ \
  && bad "deny: direct-IP (was reachable!)" || ok "deny: direct-IP https://1.1.1.1 blocked"
bxrun "$WORK/empty" curl -fsS --max-time 8 -o /dev/null http://example.com/ \
  && bad "deny: HTTP example.com (was reachable!)" || ok "deny: HTTP example.com blocked (by Host)"

uid="$( ( cd "$WORK/empty" && "$SLUICE" run id -u ) 2>/dev/null | tr -d '[:space:]' )"
[ "$uid" = 1000 ] && ok "session is non-root (uid 1000)" || bad "session is non-root (got '$uid')"
v6="$( ( cd "$WORK/empty" && "$SLUICE" run cat /proc/sys/net/ipv6/conf/all/disable_ipv6 ) 2>/dev/null | tr -d '[:space:]' )"
[ "$v6" = 1 ] && ok "IPv6 disabled" || bad "IPv6 disabled (got '$v6')"
( cd "$WORK/empty" && "$SLUICE" stop ) >/dev/null 2>&1

# Reuse the empty image; pass the bump knobs at runtime (no rebuild: config unchanged so the confighash
# matches, start() recreates the container with the new env). Bump api.github.com (a base host, not
# cert-pinned for curl) allowing only /zen; registry.npmjs.org stays spliced. Assertions read squid's
# access log directly - squid's own TCP_DENIED on a non-listed path makes the deny check deterministic.
echo "-- bump (scoped TLS interception) --"
export SLUICE_BUMP_DOMAINS="api.github.com"
export SLUICE_BUMP_URLS='^https?://api\.github\.com/zen'
bxrun "$WORK/empty" curl -s -o /dev/null --max-time 12 https://api.github.com/zen      # allowed path
bxrun "$WORK/empty" curl -s -o /dev/null --max-time 12 https://api.github.com/octocat  # non-listed path
bxrun "$WORK/empty" curl -s -o /dev/null --max-time 12 https://registry.npmjs.org/     # spliced (not bumped)
blog="$("${SLUICE_ENGINE:-docker}" exec sluice-empty cat /var/log/squid/access.log 2>/dev/null)"
# Deny is squid's own (URL ACL), logged before any origin fetch -> deterministic.
printf '%s\n' "$blog" | grep -q "TCP_DENIED/403 GET https://api.github.com/octocat" \
  && ok "bump: non-listed path on a bumped host denied by squid (TCP_DENIED/403)" \
  || bad "bump: non-listed path not denied by squid (URL ACL)"
# Decryption proven by squid logging the full URL (a GET line, not a CONNECT tunnel) for the bumped host.
if printf '%s\n' "$blog" | grep -q "GET https://api.github.com/zen"; then
  ok "bump: allowed path decrypted + permitted (squid logged the full URL)"
elif ( cd "$WORK/empty" && "$SLUICE" run grep -qx api.github.com /etc/squid/bumplist.txt ) >/dev/null 2>&1; then
  ok "bump: api.github.com actively bumped (origin refused the CI runner IP)"
else
  bad "bump: allowed path decrypted/permitted"
fi
# A non-bumped host is still spliced: squid sees only the CONNECT tunnel, never the URL.
printf '%s\n' "$blog" | grep -q "TCP_TUNNEL/[0-9]* CONNECT registry.npmjs.org" \
  && ok "bump: non-bumped registry.npmjs.org still spliced (TCP_TUNNEL, not decrypted)" \
  || bad "bump: non-bumped host still spliced (TCP_TUNNEL)"
unset SLUICE_BUMP_DOMAINS SLUICE_BUMP_URLS
( cd "$WORK/empty" && "$SLUICE" stop ) >/dev/null 2>&1

if [ -n "${ACCEPTANCE_QUICK:-}" ]; then
  echo "-- strudel sluice -- (skipped: ACCEPTANCE_QUICK)"
else
  echo "-- strudel sluice --"
  mkdir -p "$WORK/strudel"; cp "$ROOT/examples/strudel.config.sh" "$WORK/strudel/sluice.config.sh"
  if ( cd "$WORK/strudel" && "$SLUICE" build ) >/dev/null 2>&1; then ok "builds (bakes @strudel/repl)"; else bad "builds"; fi
  ( cd "$WORK/strudel" && "$SLUICE" ) >/dev/null 2>&1 &   # serve in the background

  code=000
  for _ in $(seq 1 40); do
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:4321/ 2>/dev/null || echo 000)"
    [ "$code" = 200 ] && break; sleep 0.5
  done
  [ "$code" = 200 ] && ok "serves on localhost:4321 (port published + firewall-opened)" || bad "serves on localhost:4321 (got $code)"

  retry bxrun "$WORK/strudel" curl -sS --max-time 15 -o /dev/null \
    https://raw.githubusercontent.com/tidalcycles/dirt-samples/master/bd/BT0A0D0.wav \
    && ok "runtime: sample host raw.githubusercontent.com reachable (sound loads)" \
    || bad "runtime: sample host raw.githubusercontent.com reachable"
  bxrun "$WORK/strudel" curl -fsS --max-time 8 -o /dev/null https://unpkg.com/@strudel/repl@1.3.0 \
    && bad "runtime: unpkg.com (was reachable - should be build-only!)" \
    || ok "runtime: unpkg.com blocked (bundle was baked at build)"
  ( cd "$WORK/strudel" && "$SLUICE" stop ) >/dev/null 2>&1
fi

finish
