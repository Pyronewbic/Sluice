#!/usr/bin/env bash
# Build-smoke each runtime example end-to-end: `sluice build` -> serve -> curl, through the
# sandbox, with the app's dependency fetched through the egress proxy. This is the slow
# integration layer (real toolchains + network), so it runs nightly / on demand - NOT on the
# PR gate (that stays the fast egress acceptance + init-detection unit tests).
#
# Each example is copied to a temp workdir first, so build artifacts never touch the repo.
#   test/verify-runtimes.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

EXAMPLES="${RUNTIMES:-deno ruby rust go bun poetry uv}"

echo "== sluice runtime build-smoke =="
for name in $EXAMPLES; do
  src="$ROOT/examples/$name"
  [ -f "$src/sluice.config.sh" ] || { bad "$name: missing example"; continue; }
  port="$(grep -E '^SLUICE_PORTS=' "$src/sluice.config.sh" | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
  [ -n "$port" ] || { bad "$name: no SLUICE_PORTS in config"; continue; }

  work="$(mktemp -d)/$name"; mkdir -p "$work"; cp -R "$src"/. "$work/"
  echo "-- $name (port $port) --"
  if ! ( cd "$work" && "$SLUICE" build ) >"/tmp/verify-$name.log" 2>&1; then
    bad "$name: build (see /tmp/verify-$name.log)"
    ( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1; rm -rf "$(dirname "$work")"; continue
  fi
  ( cd "$work" && "$SLUICE" ) >>"/tmp/verify-$name.log" 2>&1 &
  code=000
  for _ in $(seq 1 180); do
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/" 2>/dev/null || echo 000)"
    [ "$code" = 200 ] && break; sleep 1
  done
  if [ "$code" = 200 ]; then
    ok "$name: serves 200 (deps fetched through the proxy)"
  else
    bad "$name: serve (got $code)"
    echo "----- build+serve log ($name) -----"; tail -60 "/tmp/verify-$name.log" 2>/dev/null
    echo "----- container state -----"; "${SLUICE_ENGINE:-docker}" ps -a --filter "name=sluice-$name" 2>/dev/null
    echo "----- port map -----"; "${SLUICE_ENGINE:-docker}" port "sluice-$name" 2>/dev/null || true
    echo "-----------------------------------"
  fi
  ( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
  rm -rf "$(dirname "$work")"
done

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
