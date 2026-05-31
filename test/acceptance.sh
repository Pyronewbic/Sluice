#!/usr/bin/env bash
# sluice acceptance tests. Builds the example sluices and asserts the security + serving
# invariants end-to-end. Engine-agnostic — honours SLUICE_ENGINE (docker or podman). Exits
# non-zero on any failure, so it doubles as the CI gate.
#
#   test/acceptance.sh            # run everything
#   ACCEPTANCE_QUICK=1 …          # skip the (slower) Strudel serve test
#   SLUICE_ENGINE=podman …           # run against podman instead of docker
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
WORK="$(mktemp -d)"
PASS=0 FAIL=0

cleanup() {
  for d in empty strudel; do ( cd "$WORK/$d" 2>/dev/null && "$SLUICE" stop ) >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
# assert_block "label" <cmd...>: PASS if the command FAILS (egress blocked).
# assert_pass  "label" <cmd...>: PASS if the command SUCCEEDS.
bxrun() { ( cd "$1" && shift && "$SLUICE" run "$@" ) >/dev/null 2>&1; }
# Allow-checks: success = the connection REACHED the host (the proxy allowed it), not 2xx —
# so they use plain `curl -sS` (no -f). A 4xx like github.com rate-limiting CI runner IPs
# (429) still means "allowed". They also retry, so a single transient blip isn't a failure.
# (Deny-checks keep -f — squid's 403 page for a blocked HTTP host must read as failure — and
# aren't retried, since they pass when curl fails, which a blip only helps.)
retry() { local n=1; until "$@"; do [ "$n" -ge 3 ] && return 1; n=$((n+1)); sleep 2; done; }

echo "== sluice acceptance (engine: ${SLUICE_ENGINE:-docker}) =="

# --- empty sluice: build + egress matrix ------------------------------------------
echo "-- empty sluice --"
mkdir -p "$WORK/empty"; printf 'SLUICE_RUN_CMD="bash"\n' > "$WORK/empty/sluice.config.sh"
if ( cd "$WORK/empty" && "$SLUICE" build ) >/dev/null 2>&1; then ok "builds"; else bad "builds"; fi
( cd "$WORK/empty" && "$SLUICE" run true ) >/dev/null 2>&1   # bring the container up

retry bxrun "$WORK/empty" curl -sS --max-time 15 -o /dev/null https://registry.npmjs.org/ \
  && ok "allow: registry.npmjs.org reachable (spliced by SNI)" || bad "allow: registry.npmjs.org reachable"
retry bxrun "$WORK/empty" curl -sS --max-time 15 -o /dev/null https://github.com/ \
  && ok "allow: github.com reachable" || bad "allow: github.com reachable"
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

# --- strudel sluice: build + serve + sample egress --------------------------------
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
    && bad "runtime: unpkg.com (was reachable — should be build-only!)" \
    || ok "runtime: unpkg.com blocked (bundle was baked at build)"
  ( cd "$WORK/strudel" && "$SLUICE" stop ) >/dev/null 2>&1
fi

# --- summary -------------------------------------------------------------------
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
