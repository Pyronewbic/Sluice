#!/usr/bin/env bash
# Build-smoke each runtime fixture (build -> serve -> curl, deps through the proxy). Slow
# integration layer; runs nightly/on-demand, not the PR gate. Each fixture (test/fixtures/<rt>)
# is copied to a temp dir first so build artifacts never touch the repo.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

EXAMPLES="${RUNTIMES:-deno ruby rust go bun poetry uv}"

echo "== sluice runtime build-smoke =="
for name in $EXAMPLES; do
  src="$ROOT/test/fixtures/$name"
  [ -f "$src/sluice.config.sh" ] || { bad "$name: missing fixture"; continue; }
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
    # On the final failed serve, dump squid's own view before teardown: a terminated TLS
    # request shows the client only an opaque error, so the SNI/status + DNS live in the box.
    if [ "$code" != 200 ] && [ "$code" != build ] && [ "$attempt" = 2 ]; then
      eng="${SLUICE_ENGINE:-docker}"; c="sluice-$name"
      echo "----- DEBUG squid access.log ($name) -----"
      "$eng" exec "$c" sh -c 'tail -50 /var/log/squid/access.log' 2>&1 | tail -50
      echo "----- DEBUG squid cache.log ($name) -----"
      "$eng" exec "$c" sh -c 'tail -30 /var/log/squid/cache.log' 2>&1 | tail -30
      echo "----- DEBUG dns A/AAAA + base-allowed splice control ($name) -----"
      "$eng" exec "$c" sh -c '
        for h in index.crates.io static.crates.io proxy.golang.org jsr.io registry.npmjs.org; do
          printf "  %-22s A:%s AAAA:%s\n" "$h" "$(dig +short A "$h" 2>/dev/null | tr "\n" ",")" "$(dig +short AAAA "$h" 2>/dev/null | tr "\n" ",")"
        done
        echo "  -- curl -v https://registry.npmjs.org/ (base-allowed; does splice work at all?) --"
        curl -sv --max-time 8 -o /dev/null https://registry.npmjs.org/ 2>&1 | grep -iE "trying|connected|alpn|HTTP/|wrong version|refused|timed out|unable" | head -12
      ' 2>&1 | head -60
      echo "-------------------------------------------"
    fi
    # The entrypoint chowns the mounted copy to the sandbox uid (1000); chown it back to the
    # host uid (while the container is still up) so this harness can remove its own temp copy
    # without the "rm: Permission denied" noise on Linux (no-op on Docker Desktop's uid mapping).
    "${SLUICE_ENGINE:-docker}" exec --user root "sluice-$name" \
      chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
    ( cd "$work" && "$SLUICE" stop ) >/dev/null 2>&1
    rm -rf "$(dirname "$work")" 2>/dev/null || true
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
