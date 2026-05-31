#!/usr/bin/env bash
# Build-smoke each runtime example (build -> serve -> curl, deps through the proxy). Slow
# integration layer; runs nightly/on-demand, not the PR gate. Each example is copied to a
# temp dir first so build artifacts never touch the repo.
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

  echo "-- $name (port $port) --"
  # Retry once: the runtime dep-fetch through the proxy is an occasional CDN/CI flake.
  code=000
  for attempt in 1 2; do
    work="$(mktemp -d)/$name"; mkdir -p "$work"; cp -R "$src"/. "$work/"
    if ( cd "$work" && "$SLUICE" build ) >"/tmp/verify-$name.log" 2>&1; then
      ( cd "$work" && "$SLUICE" ) >>"/tmp/verify-$name.log" 2>&1 &
      code=000
      for _ in $(seq 1 180); do
        code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/" 2>/dev/null || echo 000)"
        [ "$code" = 200 ] && break; sleep 1
      done
    else
      code=build
    fi
    ( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
    rm -rf "$(dirname "$work")"
    [ "$code" = 200 ] && break
    [ "$attempt" = 1 ] && echo "  ... $name failed (got $code) - retrying once"
  done
  if [ "$code" = 200 ]; then
    ok "$name: serves 200 (deps fetched through the proxy)"
  else
    bad "$name: $([ "$code" = build ] && echo build || echo "serve (got $code)") (after retry)"
    echo "----- build+serve log ($name) -----"; tail -60 "/tmp/verify-$name.log" 2>/dev/null
    echo "----- container state -----"; "${SLUICE_ENGINE:-docker}" ps -a --filter "name=sluice-$name" 2>/dev/null
    echo "-----------------------------------"
  fi
done

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
