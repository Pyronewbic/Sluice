#!/usr/bin/env bash
# Build-smoke each runtime fixture (build -> serve -> curl, deps through the proxy). Slow
# integration layer; nightly/on-demand, not the PR gate. Each fixture (test/fixtures/<rt>) is copied
# to a temp dir so build artifacts never touch the repo. Runs up to VERIFY_JOBS (default 3) fixtures
# in parallel and curls each app from INSIDE its own container - so no host ports are published and
# fixtures that share a port (deno/poetry/uv on 8000, go/rust on 8080) never clash.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUICE="$ROOT/bin/sluice"
ENG="${SLUICE_ENGINE:-docker}"
JOBS="${VERIFY_JOBS:-3}"
EXAMPLES="${RUNTIMES:-deno ruby rust go bun poetry uv}"
RESULTS="$(mktemp -d)"
trap 'rm -rf "$RESULTS" 2>/dev/null || true' EXIT

# Build + serve one fixture, curling it from inside its own container. Writes "ok <msg>" / "bad <msg>"
# to $RESULTS/<name> and verbose output to $RESULTS/<name>.log. Self-contained: touches no shared
# state, so it is safe to run many in parallel.
run_one() {
  local name="$1" c="sluice-$1" log="$RESULTS/$1.log" src port work code attempt
  : > "$log"
  src="$ROOT/test/fixtures/$name"
  [ -f "$src/sluice.config.sh" ] || { echo "bad $name: missing fixture" > "$RESULTS/$name"; return; }
  port="$(grep -E '^SLUICE_PORTS=' "$src/sluice.config.sh" | sed -E 's/[^0-9]*([0-9]+).*/\1/')"
  [ -n "$port" ] || { echo "bad $name: no SLUICE_PORTS in config" > "$RESULTS/$name"; return; }

  code=000
  # Retry once: the runtime dep-fetch through the proxy is an occasional CDN/CI flake.
  for attempt in 1 2; do
    work="$(mktemp -d)/$name"; mkdir -p "$work"; cp -R "$src"/. "$work/"
    # Blank SLUICE_PORTS so no host port is published (would clash across parallel jobs); the app
    # still binds its own port and we curl it in-container. Last assignment wins when sourced.
    printf '\nSLUICE_PORTS=""\n' >> "$work/sluice.config.sh"
    if ( cd "$work" && "$SLUICE" build ) >>"$log" 2>&1; then
      ( cd "$work" && "$SLUICE" ) >>"$log" 2>&1 &   # serve in the background (idle box + RUN_CMD)
      code=000
      for _ in $(seq 1 180); do   # exec fails until the container is up, then until the app serves
        code="$("$ENG" exec "$c" curl -fsS -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$port/" 2>/dev/null || echo 000)"
        [ "$code" = 200 ] && break; sleep 1
      done
    else
      code=build
    fi
    # On the final failed serve, dump squid's own view: a terminated TLS request shows the client
    # only an opaque error, so the SNI/status + DNS live in the box.
    if [ "$code" != 200 ] && [ "$code" != build ] && [ "$attempt" = 2 ]; then
      {
        echo "----- DEBUG squid access.log ($name) -----"
        "$ENG" exec "$c" sh -c 'tail -50 /var/log/squid/access.log' 2>&1 | tail -50
        echo "----- DEBUG squid cache.log ($name) -----"
        "$ENG" exec "$c" sh -c 'tail -30 /var/log/squid/cache.log' 2>&1 | tail -30
        echo "----- DEBUG dns + base-allowed splice control ($name) -----"
        "$ENG" exec "$c" sh -c '
          for h in index.crates.io static.crates.io proxy.golang.org jsr.io registry.npmjs.org; do
            printf "  %-22s A:%s AAAA:%s\n" "$h" "$(dig +short A "$h" 2>/dev/null | tr "\n" ",")" "$(dig +short AAAA "$h" 2>/dev/null | tr "\n" ",")"
          done
          echo "  -- curl -v https://registry.npmjs.org/ (base-allowed; does splice work at all?) --"
          curl -sv --max-time 8 -o /dev/null https://registry.npmjs.org/ 2>&1 | grep -iE "trying|connected|alpn|HTTP/|wrong version|refused|timed out|unable" | head -12
        ' 2>&1 | head -60
      } >>"$log" 2>&1
    fi
    # Entrypoint chowned the mount to uid 1000; chown back (container still up) so we can rm the copy.
    "$ENG" exec --user root "$c" chown -R "$(id -u):$(id -g)" "$work" >/dev/null 2>&1 || true
    ( cd "$work" && "$SLUICE" stop ) >>"$log" 2>&1
    rm -rf "$(dirname "$work")" 2>/dev/null || true
    [ "$code" = 200 ] && break
  done

  if [ "$code" = 200 ]; then
    echo "ok $name: serves 200 in-container (deps fetched through the proxy)" > "$RESULTS/$name"
  else
    echo "bad $name: $([ "$code" = build ] && echo build || echo "serve (got $code)") (after retry)" > "$RESULTS/$name"
  fi
}

echo "== sluice runtime build-smoke (up to $JOBS parallel, in-container curl) =="
for name in $EXAMPLES; do
  echo "-- launching $name --"
  run_one "$name" &
  # Throttle to JOBS concurrent (bash 3.2 has no `wait -n`, so poll the running-job count).
  while [ "$(jobs -r -p | wc -l)" -ge "$JOBS" ]; do sleep 0.5; done
done
wait

PASS=0 FAIL=0
echo "== results =="
for name in $EXAMPLES; do
  res="$(cat "$RESULTS/$name" 2>/dev/null || echo "bad $name: no result file")"
  if [ "${res%% *}" = ok ]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "${res#ok }"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n' "${res#bad }"
    echo "----- log ($name) -----"; tail -60 "$RESULTS/$name.log" 2>/dev/null
    echo "----- container state -----"; "$ENG" ps -a --filter "name=sluice-$name" 2>/dev/null
    echo "-----------------------------------"
  fi
done

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
